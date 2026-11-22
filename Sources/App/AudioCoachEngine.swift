import Foundation
@preconcurrency import AVFoundation
import Combine

/// Resumes a continuation at most once, from whichever path (playback
/// completion or safety timeout) gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Thread-safe accumulator for speech-synthesis chunks.
private final class ChunkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [AVAudioPCMBuffer] = []
    func append(_ b: AVAudioPCMBuffer) { lock.lock(); chunks.append(b); lock.unlock() }
    func all() -> [AVAudioPCMBuffer] { lock.lock(); defer { lock.unlock() }; return chunks }
}

/// Context the bag-coach loop reads from the workout session.
struct BagLoopContext {
    var isWorkPhase: () -> Bool
    var roundProgress: () -> Double
    /// Seconds left in the current work phase, or nil when there's no round timer.
    var workRemaining: () -> Double?
    /// −1 below the plan's HR band, 0 inside (or no plan), +1 above.
    var hrBandStatus: () -> Int
}

/// All workout audio: bag-work combos, coach announcements and bells, each on its
/// own player so they never queue behind one another.
@MainActor
final class AudioCoachEngine: NSObject, ObservableObject {
    // Bag-coach display state
    @Published private(set) var comboTokens: [String] = []
    @Published private(set) var activeTokenIndex: Int = -1
    @Published private(set) var comboSerial: Int = 0
    @Published private(set) var bagStatus: String = ""
    @Published var strikesCuedCount: Int = 0
    /// Called after each combo finishes being called (used to measure each combo's HR cost).
    var onComboPlayed: (@MainActor ([Strike]) -> Void)?
    @Published private(set) var isPreparingAudio = false
    @Published private(set) var preparationProgress: Double = 0
    @Published private(set) var voiceName: String = ""

    private let engine = AVAudioEngine()
    private let comboNode = AVAudioPlayerNode()
    private let voiceNode = AVAudioPlayerNode()
    private let fxNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    private let vocabSynth = AVSpeechSynthesizer()
    private let voiceSynth = AVSpeechSynthesizer()
    private var graphReady = false
    private var audioEnabled = true
    private var duckMusic = true

    private var phraseCache: [String: AVAudioPCMBuffer] = [:]
    private var cachedRate: Float = 0
    private var bagTask: Task<Void, Never>?
    private var isComboSpeaking = false

    private struct Announcement { let text: String; let created: Date }
    private var announcementQueue: [Announcement] = []
    private var announcementTask: Task<Void, Never>?

    private lazy var bellBuffer = Self.bell(strikes: 1)
    private lazy var tripleBellBuffer = Self.bell(strikes: 3)
    private lazy var clapperBuffer = Self.clapper()

    private lazy var bestVoice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            var r = 0
            switch v.quality {
            case .premium: r += 300
            case .enhanced: r += 200
            default: r += 100
            }
            if v.language == "en-US" { r += 20 }
            if v.voiceTraits.contains(.isNoveltyVoice) { r -= 500 }
            return r
        }
        return english.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    override init() {
        super.init()
        buildGraph()
        voiceName = bestVoice?.name ?? "System voice"
        observeInterruptions()
    }

    /// A phone call, Siri or another app taking the audio stops the engine; so does plugging in or
    /// unplugging headphones. Bring bells, voice and bag-hit counting back as soon as it's over.
    /// Called when a phone call (or another app) interrupts audio during a session.
    var onInterruptionBegan: (@MainActor () -> Void)?

    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    self.wasRunningBeforeInterruption = self.engine.isRunning
                    // A phone call (or similar) took the audio: let the session pause.
                    if self.audioEnabled { self.onInterruptionBegan?() }
                } else if self.wasRunningBeforeInterruption {
                    self.resumeAfterInterruption()
                }
            }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Only if a session is using the audio (never wake it up when the app is idle).
                guard let self, self.isBagCoachRunning || self.hitTapInstalled else { return }
                self.resumeAfterInterruption()
            }
        }
    }

    private func resumeAfterInterruption() {
        guard audioEnabled else { return }
        removeHitTap()          // re-installed with the new input format
        ensureEngineRunning()
    }

    // MARK: Engine & session

    private func buildGraph() {
        guard !graphReady else { return }
        for node in [comboNode, voiceNode, fxNode] {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        graphReady = true
    }

    /// Applies the athlete's audio settings (volumes, music ducking).
    func configure(settings: AudioCoachSettings) {
        comboNode.volume = Float(settings.voiceVolume)
        voiceNode.volume = Float(settings.voiceVolume)
        fxNode.volume = Float(settings.bellVolume)
        if duckMusic != settings.duckMusic {
            duckMusic = settings.duckMusic
            if engine.isRunning { try? activateSession() }
        }
    }

    /// Listen for bag hits with the phone's microphone (set before the workout starts).
    var countBagHits = false {
        didSet {
            guard oldValue != countBagHits, engine.isRunning else { return }
            engine.stop()
            if !countBagHits { removeHitTap() }
            ensureEngineRunning()
        }
    }
    /// Called on the main actor for every bag hit heard.
    var onBagHit: (@MainActor () -> Void)?
    private var hitTapInstalled = false
    private var wasRunningBeforeInterruption = false
    private let hitDetector = ImpactDetectorBox()

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if duckMusic { options.insert(.duckOthers) }
        if countBagHits {
            // A2DP only: AirPods keep full-quality sound, and the phone's own mic listens.
            options.formUnion([.allowBluetoothA2DP, .defaultToSpeaker])
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        } else {
            try session.setCategory(.playback, mode: .spokenAudio, options: options)
        }
        try session.setActive(true)
    }

    private func installHitTapIfNeeded() {
        guard countBagHits, !hitTapInstalled else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        hitDetector.reset(sampleRate: format.sampleRate)
        let box = hitDetector
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let hits = box.feed(data, count: Int(buffer.frameLength))
            guard hits > 0 else { return }
            Task { @MainActor in
                for _ in 0..<hits { self?.onBagHit?() }
            }
        }
        hitTapInstalled = true
    }

    private func removeHitTap() {
        guard hitTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        hitTapInstalled = false
    }

    private func ensureEngineRunning() {
        guard graphReady, audioEnabled else { return }
        if !engine.isRunning {
            do {
                try activateSession()
                installHitTapIfNeeded()
                try engine.start()
            } catch {
                print("Audio start error: \(error)")
                return
            }
        }
        for node in [comboNode, voiceNode, fxNode] where !node.isPlaying {
            node.play()
        }
    }

    /// Starts audio for a workout. The running engine also keeps the app alive in
    /// the background (UIBackgroundModes: audio) so round timing stays accurate.
    func prepareForWorkout(settings: AudioCoachSettings) {
        audioEnabled = true
        configure(settings: settings)
        ensureEngineRunning()
    }

    /// Stops all audio and releases the session after a workout.
    func shutdownAudio() {
        audioEnabled = false
        stopBagCoach()
        announcementTask?.cancel()
        announcementTask = nil
        announcementQueue.removeAll()
        for node in [comboNode, voiceNode, fxNode] { node.stop() }
        engine.stop()
        removeHitTap()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Speech rendering

    /// Pre-renders every phrase the bag coach can say, so the first round starts instantly.
    func prepareVocabulary(prefs: BagPreferences) async {
        // One preparation at a time: a second caller waits, then fills in anything still missing.
        while isPreparingAudio {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let rate = prefs.tempo.speechRate
        if rate != cachedRate {
            phraseCache.removeAll()
            cachedRate = rate
        }
        let phrases = ComboGenerator.vocabulary(prefs: prefs).filter { phraseCache[$0] == nil }
        guard !phrases.isEmpty else { return }
        isPreparingAudio = true
        preparationProgress = 0
        for (i, phrase) in phrases.enumerated() {
            if Task.isCancelled { break }
            if let saved = VoiceDiskCache.load(phrase, voice: bestVoice?.identifier, rate: rate) {
                phraseCache[phrase] = saved
            } else if let buf = await render(phrase, rate: rate, synth: vocabSynth) {
                phraseCache[phrase] = buf
                VoiceDiskCache.save(buf, phrase: phrase, voice: bestVoice?.identifier, rate: rate)
            }
            preparationProgress = Double(i + 1) / Double(phrases.count)
        }
        isPreparingAudio = false
    }

    private func render(_ text: String, rate: Float, synth: AVSpeechSynthesizer) async -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice
        utterance.rate = rate
        utterance.pitchMultiplier = 1.05
        utterance.volume = 1.0

        let box = ChunkBox()
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<AVAudioPCMBuffer?, Never>) in
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength > 0 {
                    box.append(pcm)
                } else if once.claim() {
                    continuation.resume(returning: Self.prepare(chunks: box.all()))
                }
            }
            // Some iOS versions never deliver the final empty buffer: don't hang.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if once.claim() {
                    continuation.resume(returning: Self.prepare(chunks: box.all()))
                }
            }
        }
    }

    private nonisolated static func prepare(chunks: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let merged = mergeAndResample(chunks: chunks, targetRate: 22050) else { return nil }
        return trimSilence(merged)
    }

    private nonisolated static func mergeAndResample(chunks: [AVAudioPCMBuffer], targetRate: Double) -> AVAudioPCMBuffer? {
        guard let first = chunks.first else { return nil }
        let totalFrames = chunks.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0,
              let monoSource = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: first.format.sampleRate, channels: 1, interleaved: false),
              let combined = AVAudioPCMBuffer(pcmFormat: monoSource, frameCapacity: AVAudioFrameCount(totalFrames)),
              let dst = combined.floatChannelData?[0] else {
            return nil
        }
        combined.frameLength = AVAudioFrameCount(totalFrames)
        var offset = 0
        for chunk in chunks {
            let count = Int(chunk.frameLength)
            if let f = chunk.floatChannelData?[0] {
                dst.advanced(by: offset).update(from: f, count: count)
            } else if let i16 = chunk.int16ChannelData?[0] {
                for i in 0..<count { dst[offset + i] = Float(i16[i]) / 32768.0 }
            }
            offset += count
        }
        if abs(monoSource.sampleRate - targetRate) < 1 { return combined }

        guard let target = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1),
              let converter = AVAudioConverter(from: monoSource, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(totalFrames) * targetRate / monoSource.sampleRate) + 64) else {
            return combined
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return combined
        }
        return out.frameLength > 0 ? out : combined
    }

    /// Removes the synthesizer's leading/trailing silence so callouts are snappy.
    nonisolated static func trimSilence(_ buf: AVAudioPCMBuffer, threshold: Float = 0.012, padSeconds: Double = 0.025) -> AVAudioPCMBuffer {
        guard let data = buf.floatChannelData?[0] else { return buf }
        let n = Int(buf.frameLength)
        guard n > 0 else { return buf }
        var start = 0
        while start < n && abs(data[start]) < threshold { start += 1 }
        var end = n - 1
        while end > start && abs(data[end]) < threshold { end -= 1 }
        guard start < end else { return buf }
        let pad = Int(padSeconds * buf.format.sampleRate)
        start = max(0, start - pad)
        end = min(n - 1, end + pad)
        let count = end - start + 1
        guard count < n,
              let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(count)),
              let dst = out.floatChannelData?[0] else { return buf }
        dst.update(from: data.advanced(by: start), count: count)
        out.frameLength = AVAudioFrameCount(count)
        return out
    }

    // MARK: Playback

    private static func duration(_ buffers: [AVAudioPCMBuffer]) -> Double {
        buffers.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
    }

    /// Schedules buffers back-to-back and returns once the last one has actually
    /// been heard (or a safety timeout passes). `onAdvance(i)` fires as buffer i begins.
    private func playAndWait(_ buffers: [AVAudioPCMBuffer], on node: AVAudioPlayerNode, onAdvance: (@MainActor (Int) -> Void)? = nil) async {
        guard !buffers.isEmpty else { return }
        ensureEngineRunning()
        let total = Self.duration(buffers)
        hitDetector.noteOwnSound(seconds: total)
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            for (i, buf) in buffers.enumerated() {
                let isLast = i == buffers.count - 1
                node.scheduleBuffer(buf, completionCallbackType: isLast ? .dataPlayedBack : .dataRendered) { _ in
                    if isLast {
                        if once.claim() { continuation.resume() }
                    } else if let onAdvance {
                        Task { @MainActor in onAdvance(i + 1) }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.9) {
                if once.claim() { continuation.resume() }
            }
        }
    }

    // MARK: Bells

    func playRoundStartBell() {
        ensureEngineRunning()
        if let b = bellBuffer { playFX(b) }
    }

    func playRoundEndBell() {
        ensureEngineRunning()
        if let b = tripleBellBuffer { playFX(b) }
    }

    /// Soft breathing guide tone: rising pitch = breathe in, falling = breathe out.
    func playBreathCue(inhale: Bool, seconds: Double) {
        ensureEngineRunning()
        if let b = Self.breathTone(rising: inhale, seconds: seconds) {
            playFX(b)
        }
    }

    /// Plays a sound effect and tells the bag-hit listener it isn't a hit.
    private func playFX(_ b: AVAudioPCMBuffer) {
        hitDetector.noteOwnSound(seconds: Double(b.frameLength) / b.format.sampleRate)
        fxNode.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
    }

    private static func breathTone(rising: Bool, seconds: Double) -> AVAudioPCMBuffer? {
        let sr = 22050.0
        let length = min(max(seconds, 1), 8)
        let frames = Int(sr * length)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let d = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        let f0 = rising ? 220.0 : 330.0
        let f1 = rising ? 330.0 : 220.0
        var phase = 0.0
        for i in 0..<frames {
            let t = Double(i) / sr
            let u = t / length
            let f = f0 + (f1 - f0) * u
            phase += 2 * .pi * f / sr
            // Gentle swell in and out.
            let env = sin(.pi * u) * 0.22
            d[i] = Float(sin(phase) * env + sin(phase * 2) * env * 0.15)
        }
        return buf
    }

    /// Two sharp claps: the gym's "10 seconds" warning.
    func playClapper() {
        ensureEngineRunning()
        if let b = clapperBuffer { playFX(b) }
    }

    private static func bell(strikes: Int) -> AVAudioPCMBuffer? {
        let sr = 22050.0
        let strikeGap = 0.32
        let ring = 1.1
        let length = Double(strikes - 1) * strikeGap + ring
        let frames = Int(sr * length)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let d = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        // Inharmonic partials give a metallic bell timbre.
        let partials: [(Double, Float)] = [(1318.5, 0.5), (2637.0, 0.22), (3520.0, 0.14), (987.8, 0.18)]
        for i in 0..<frames {
            let t = Double(i) / sr
            var v: Float = 0
            for k in 0..<strikes {
                let tk = t - Double(k) * strikeGap
                guard tk >= 0 else { continue }
                let env = Float(exp(-tk * 4.2))
                for (f, a) in partials { v += a * env * Float(sin(2 * .pi * f * tk)) }
            }
            d[i] = max(-1, min(1, v * 0.7))
        }
        return buf
    }

    private static func clapper() -> AVAudioPCMBuffer? {
        let sr = 22050.0
        let frames = Int(sr * 0.32)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let d = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        var seed: UInt32 = 12345
        for i in 0..<frames {
            let t = Double(i) / sr
            var v: Float = 0
            for start in [0.0, 0.16] {
                let tk = t - start
                guard tk >= 0, tk < 0.09 else { continue }
                seed = seed &* 1664525 &+ 1013904223
                let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
                let env = Float(exp(-tk * 60))
                v += (noise * 0.6 + Float(sin(2 * .pi * 1800 * tk)) * 0.4) * env
            }
            d[i] = max(-1, min(1, v * 0.9))
        }
        return buf
    }

    /// One buffer containing an entire beep pattern, so timing is sample-accurate.
    private static func beepPattern(for strikes: [Strike]) -> AVAudioPCMBuffer? {
        let sr = 22050.0
        var events: [(start: Double, freq: Double, dur: Double)] = []
        var t = 0.0
        for s in strikes {
            switch s.kind {
            case .punch: events.append((t, 1046.5, 0.08)); t += 0.24
            case .kick: events.append((t, 659.3, 0.14)); t += 0.40
            case .knee, .elbow: events.append((t, 830.6, 0.07)); events.append((t + 0.1, 830.6, 0.07)); t += 0.34
            case .defense: events.append((t, 1318.5, 0.06)); events.append((t + 0.08, 987.8, 0.08)); t += 0.34
            }
        }
        let frames = Int(sr * (t + 0.1))
        guard frames > 0,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let d = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { d[i] = 0 }
        for e in events {
            let s0 = Int(e.start * sr)
            let n = Int(e.dur * sr)
            for j in 0..<n where s0 + j < frames {
                let tt = Double(j) / sr
                d[s0 + j] += Float(sin(2 * .pi * e.freq * tt) * exp(-tt * 18)) * 0.6
            }
        }
        return buf
    }

    // MARK: Bag coach

    var isBagCoachRunning: Bool { bagTask != nil }
    /// Set by the session before the bag coach starts (see ComboGenerator).
    var focusStrikes: Set<Strike> = []
    var avoidComboLabels: Set<String> = []

    func startBagCoach(prefs: BagPreferences, context: BagLoopContext) {
        stopBagCoach()
        bagStatus = "READY — HANDS UP"
        bagTask = Task { [weak self] in
            guard let self else { return }
            var generator = ComboGenerator(prefs: prefs)
            generator.focusStrikes = self.focusStrikes
            generator.avoidLabels = self.avoidComboLabels
            if prefs.mode != .cadenceBeep {
                await self.prepareVocabulary(prefs: prefs)
            }
            self.ensureEngineRunning()
            var punchOutCalled = false

            while !Task.isCancelled {
                guard context.isWorkPhase() else {
                    punchOutCalled = false
                    self.setRestDisplay()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                // Final 10 seconds of the round: continuous straight punches.
                if let remaining = context.workRemaining(), remaining <= 10.5 {
                    if !punchOutCalled {
                        punchOutCalled = true
                        self.comboTokens = ["PUNCH OUT!"]
                        self.activeTokenIndex = 0
                        self.comboSerial += 1
                        self.bagStatus = ""
                        if let b = self.phraseCache["Punch out!"] {
                            self.isComboSpeaking = true
                            await self.playAndWait([b], on: self.comboNode)
                            self.isComboSpeaking = false
                        }
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                let combo = generator.next()
                await self.perform(combo: combo, prefs: prefs, context: context)
            }
        }
    }

    private func perform(combo: [Strike], prefs: BagPreferences, context: BagLoopContext) async {
        let texts = combo.map { $0.callout(stance: prefs.stance, numbers: prefs.numberCalls) }
        comboTokens = combo.map { $0.callout(stance: prefs.stance, numbers: prefs.numberCalls).replacingOccurrences(of: "!", with: "").uppercased() }
        activeTokenIndex = 0
        comboSerial += 1
        bagStatus = ""
        isComboSpeaking = true

        var spoken = combo.count
        switch prefs.mode {
        case .voiceCombos:
            let buffers = texts.compactMap { phraseCache[$0] }
            spoken = buffers.count
            await playAndWait(buffers, on: comboNode) { [weak self] i in self?.activeTokenIndex = i }
        case .cadenceBeep:
            if let pattern = Self.beepPattern(for: combo) {
                activeTokenIndex = combo.count - 1
                await playAndWait([pattern], on: comboNode)
            }
        case .hybrid:
            if let pattern = Self.beepPattern(for: [combo[0]]) {
                await playAndWait([pattern], on: comboNode)
            }
            let buffers = texts.compactMap { phraseCache[$0] }
            spoken = buffers.count
            await playAndWait(buffers, on: comboNode) { [weak self] i in self?.activeTokenIndex = i }
        }
        isComboSpeaking = false
        guard !Task.isCancelled, context.isWorkPhase() else { return }
        activeTokenIndex = combo.count
        strikesCuedCount += spoken   // only what was actually called out
        onComboPlayed?(combo)

        // Throwing time, then the tempo's reset — adapted to the HR plan if enabled.
        let progress = context.roundProgress()
        let execution = combo.reduce(0) { $0 + $1.executionSeconds } * (prefs.tempo == .burnout ? 0.8 : 1.0)
        var reset = Double.random(in: prefs.tempo.resetRange(roundProgress: progress))
        if prefs.adaptiveTempo {
            switch context.hrBandStatus() {
            case -1: reset *= 0.7
            case 1: reset *= 1.4
            default: break
            }
        }
        await sleepWhileWorking(execution + reset, context: context)
    }

    /// Sleeps in short steps so a bell or "punch out" interrupts immediately.
    private func sleepWhileWorking(_ seconds: Double, context: BagLoopContext) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !Task.isCancelled && context.isWorkPhase() {
            if let r = context.workRemaining(), r <= 10.5 { return }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func setRestDisplay() {
        if bagStatus != "REST — BREATHE" {
            comboTokens = []
            activeTokenIndex = -1
            bagStatus = "REST — BREATHE"
        }
    }

    /// Silences any combo mid-sentence (used when the bell goes for rest).
    func flushCombos() {
        comboNode.stop()
        if audioEnabled && engine.isRunning { comboNode.play() }
        isComboSpeaking = false
        setRestDisplay()
    }

    func stopBagCoach() {
        bagTask?.cancel()
        bagTask = nil
        comboNode.stop()
        if audioEnabled && engine.isRunning { comboNode.play() }
        isComboSpeaking = false
        comboTokens = []
        activeTokenIndex = -1
        bagStatus = ""
    }

    // MARK: Coach announcements

    /// Queues a spoken coaching cue. Cues wait for gaps between combos and are
    /// dropped if they go stale, so they never talk over a combination.
    func announceCoachingCue(_ message: String, enabled: Bool) {
        guard enabled, audioEnabled else { return }
        announcementQueue.append(Announcement(text: message, created: Date()))
        if announcementQueue.count > 4 { announcementQueue.removeFirst(announcementQueue.count - 4) }
        guard announcementTask == nil else { return }
        announcementTask = Task { [weak self] in
            await self?.drainAnnouncements()
        }
    }

    private func drainAnnouncements() async {
        while !Task.isCancelled, !announcementQueue.isEmpty {
            let item = announcementQueue.removeFirst()
            // Wait (up to 8 s) for a gap in the combos.
            var waited = 0.0
            while isComboSpeaking && waited < 8 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 0.1
            }
            guard Date().timeIntervalSince(item.created) < 12 else { continue }
            if let buf = await render(item.text, rate: 0.53, synth: voiceSynth) {
                await playAndWait([buf], on: voiceNode)
            }
        }
        announcementTask = nil
    }
}

/// Rendered voice lines saved in Caches, so the bag coach starts instantly on the next launch.
/// Keyed by voice and speech rate; iOS may clear Caches, and then lines are simply rendered again.
enum VoiceDiskCache {
    private static func url(_ phrase: String, voice: String?, rate: Float) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        func safe(_ x: String) -> String {
            String(x.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        }
        let dir = caches.appendingPathComponent("VoiceCache", isDirectory: true)
            .appendingPathComponent("\(safe(voice ?? "default"))-\(Int(rate * 1000))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(safe(phrase))-\(phrase.utf8.count).pcm")
    }

    static func save(_ buffer: AVAudioPCMBuffer, phrase: String, voice: String?, rate: Float) {
        guard let url = url(phrase, voice: voice, rate: rate), let data = buffer.floatChannelData?[0] else { return }
        var sampleRate = buffer.format.sampleRate
        var out = Data(bytes: &sampleRate, count: MemoryLayout<Double>.size)
        out.append(Data(bytes: data, count: Int(buffer.frameLength) * MemoryLayout<Float>.size))
        try? out.write(to: url, options: .atomic)
    }

    static func load(_ phrase: String, voice: String?, rate: Float) -> AVAudioPCMBuffer? {
        guard let url = url(phrase, voice: voice, rate: rate), let data = try? Data(contentsOf: url),
              data.count > MemoryLayout<Double>.size else { return nil }
        let sampleRate = data.prefix(MemoryLayout<Double>.size).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        let body = data.dropFirst(MemoryLayout<Double>.size)
        let frames = body.count / MemoryLayout<Float>.size
        guard sampleRate > 0, frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        body.withUnsafeBytes { raw in
            if let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) {
                dst.update(from: src, count: frames)
            }
        }
        return buffer
    }
}
