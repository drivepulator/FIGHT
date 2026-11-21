import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import VisionKit

extension UTType {
    static let fightPlan = UTType(exportedAs: PlanTransfer.planTypeIdentifier, conformingTo: .json)
    static let fightResult = UTType(exportedAs: PlanTransfer.resultTypeIdentifier, conformingTo: .json)
}

// MARK: - Library

struct PlanLibraryView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var undo: UndoCenter
    @EnvironmentObject var navigation: AppNavigation

    @State private var editingNew = false
    @State private var showingScanner = false
    @State private var showingFileImporter = false

    var body: some View {
        List {
            Section {
                if workoutStore.plans.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No plans yet").font(.headline)
                        Text("Build your own, start from a template below, or open a plan your coach sent you (file, link or QR code).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(workoutStore.plans) { plan in
                        NavigationLink {
                            PlanDetailView(plan: plan, isTemplate: false)
                        } label: {
                            PlanRow(plan: plan, runs: workoutStore.workouts(forPlan: plan.id).count)
                        }
                    }
                    .onDelete { offsets in
                        let removed = offsets.map { workoutStore.plans[$0] }
                        let before = workoutStore.plans
                        for p in removed { workoutStore.deletePlan(p) }
                        undo.show(removed.count == 1 ? "\(removed[0].title) deleted" : "Plans deleted") {
                            for p in removed { workoutStore.upsertPlan(p) }
                            workoutStore.reorderPlans(like: before)
                        }
                    }
                    .onMove { workoutStore.movePlans(from: $0, to: $1) }
                }
            } header: {
                Text("My Plans")
            }

            Section {
                ForEach(PlanTemplates.all) { plan in
                    NavigationLink {
                        PlanDetailView(plan: plan, isTemplate: true)
                    } label: {
                        PlanRow(plan: plan, runs: nil)
                    }
                }
            } header: {
                Text("Templates")
            } footer: {
                Text("Templates are starting points. Save one to your plans to customise it.")
            }
        }
        .navigationTitle("Training Plans")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editingNew = true } label: { Label("New Plan", systemImage: "square.and.pencil") }
                    Button { showingScanner = true } label: { Label("Scan Plan QR Code", systemImage: "qrcode.viewfinder") }
                    Button { showingFileImporter = true } label: { Label("Open Plan File", systemImage: "doc") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if !workoutStore.plans.isEmpty { EditButton() }
            }
        }
        .sheet(isPresented: $editingNew) {
            PlanEditorView(plan: TrainingPlan(title: "", author: workoutStore.activeProfile.name, blocks: []), isNew: true)
        }
        .sheet(isPresented: $showingScanner) {
            PlanScannerSheet()
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.fightPlan, .json], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                navigation.handleOpenURL(url)
            }
        }
    }
}

struct PlanRow: View {
    let plan: TrainingPlan
    let runs: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.title.isEmpty ? "Untitled plan" : plan.title)
                .font(.headline)
            HStack(spacing: 8) {
                Label(PlanFormat.totalLabel(plan.plannedSeconds), systemImage: "clock")
                Label("\(plan.blocks.count) blocks", systemImage: "square.stack")
                if !plan.author.isEmpty {
                    Label(plan.author, systemImage: "person")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let runs, runs > 0 {
                Text("Done \(runs)×")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

struct PlanDetailView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation
    @Environment(\.dismiss) private var dismiss

    let plan: TrainingPlan
    let isTemplate: Bool

    @State private var editing: TrainingPlan?
    @State private var sharing = false

    /// Always show the stored (possibly edited) version.
    private var current: TrainingPlan {
        workoutStore.plans.first { $0.id == plan.id } ?? plan
    }

    var body: some View {
        let p = current
        let stance = workoutStore.activeProfile.bagPreferences.stance
        let runs = workoutStore.workouts(forPlan: p.id)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.discipline.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                    HStack(spacing: 12) {
                        Label(PlanFormat.totalLabel(p.plannedSeconds), systemImage: "clock")
                        Label("\(p.blocks.count) blocks", systemImage: "square.stack")
                    }
                    .font(.subheadline)
                    if !p.author.isEmpty {
                        Text("By \(p.author)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !p.notes.isEmpty {
                        Text(p.notes).font(.subheadline).padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)

                Button {
                    navigation.run(p)
                    dismiss()
                } label: {
                    Label("Start This Plan", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .listRowBackground(Color.clear)
            }

            Section("Blocks") {
                ForEach(p.blocks.indices, id: \.self) { i in
                    PlanBlockRow(index: i + 1, block: p.blocks[i], stance: stance, profile: workoutStore.activeProfile)
                }
            }

            if !runs.isEmpty {
                Section("History") {
                    ForEach(runs.prefix(10)) { w in
                        NavigationLink {
                            WorkoutDetailView(workout: w)
                        } label: {
                            HStack {
                                Text(w.startDate.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                let done = w.blockResults.filter(\.completed).count
                                Text("\(done)/\(w.blockResults.count) blocks")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(done == w.blockResults.count ? .green : .orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(p.title.isEmpty ? "Plan" : p.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    sharing = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Menu {
                    if isTemplate {
                        Button {
                            workoutStore.upsertPlan(p.duplicated())
                        } label: { Label("Save to My Plans", systemImage: "tray.and.arrow.down") }
                        Button {
                            editing = p.duplicated(title: p.title + " (copy)")
                        } label: { Label("Customise a Copy", systemImage: "square.and.pencil") }
                    } else {
                        Button { editing = p } label: { Label("Edit", systemImage: "square.and.pencil") }
                        Button {
                            workoutStore.upsertPlan(p.duplicated(title: p.title + " (copy)"))
                        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editing) { plan in
            PlanEditorView(plan: plan, isNew: isTemplate || !workoutStore.plans.contains { $0.id == plan.id })
        }
        .sheet(isPresented: $sharing) {
            PlanShareSheet(plan: p)
        }
    }
}

struct PlanBlockRow: View {
    let index: Int
    let block: PlanBlock
    let stance: Stance
    let profile: AthleteProfile

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.18)).frame(width: 32, height: 32)
                Image(systemName: block.kind.icon).foregroundStyle(.orange).font(.subheadline)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(index). \(block.title)").font(.subheadline.weight(.bold))
                Text("\(block.kind.displayName) • \(block.summary)" + (block.kind == .bagRounds ? " • \(block.tempo.displayName)" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !block.combos.isEmpty {
                    Text("Only: " + block.combos.map { combo in
                        combo.map { $0.shortLabel(stance: stance) }.joined(separator: "-")
                    }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if let t = block.target {
                    let r = t.bpmRange(for: profile)
                    Text("\(t.label) • \(r.lowerBound)–\(r.upperBound) BPM for you")
                        .font(.caption)
                        .foregroundStyle(.pink)
                }
                if !block.cue.isEmpty {
                    Text("“\(block.cue)”").font(.caption).italic()
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editor

struct PlanEditorView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TrainingPlan
    private let original: TrainingPlan
    let isNew: Bool

    init(plan: TrainingPlan, isNew: Bool) {
        _draft = State(initialValue: plan)
        original = plan
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan") {
                    TextField("Title (e.g. 1-2 & Low Kicks)", text: $draft.title)
                    TextField("Coach / author", text: $draft.author)
                    Picker("Discipline", selection: $draft.discipline) {
                        ForEach(WorkoutCategory.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    TextField("Notes for the fighter", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    ForEach($draft.blocks) { $block in
                        NavigationLink {
                            BlockEditorView(block: $block, stance: workoutStore.activeProfile.bagPreferences.stance)
                        } label: {
                            HStack {
                                Image(systemName: block.kind.icon).foregroundStyle(.orange).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(block.title).font(.subheadline.weight(.semibold))
                                    Text(block.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { draft.blocks.remove(atOffsets: $0) }
                    .onMove { draft.blocks.move(fromOffsets: $0, toOffset: $1) }

                    Menu {
                        ForEach(PlanBlockKind.allCases) { kind in
                            Button {
                                draft.blocks.append(PlanBlock(kind: kind))
                            } label: {
                                Label(kind.displayName, systemImage: kind.icon)
                            }
                        }
                    } label: {
                        Label("Add Block", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Blocks")
                } footer: {
                    Text("Total about \(PlanFormat.totalLabel(draft.plannedSeconds)), plus short transitions. Tap a block to edit, drag to reorder.")
                }
            }
            .navigationTitle(isNew ? "New Plan" : "Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(draft != original)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    EditButton()
                }
                ToolbarItem(placement: .cancellationAction) {
                    DiscardChangesButton(hasChanges: draft != original) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var p = draft
                        p.title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if p.title.isEmpty { p.title = "Untitled plan" }
                        workoutStore.upsertPlan(p)
                        dismiss()
                    }
                    .disabled(draft.blocks.isEmpty)
                }
            }
        }
    }
}

struct BlockEditorView: View {
    @Binding var block: PlanBlock
    let stance: Stance
    @AppStorage("fight.advanced.block") private var showAdvanced = false

    /// Advanced options already in use stay visible so nothing is hidden by surprise.
    private var usesAdvanced: Bool {
        block.target != nil || !block.cue.isEmpty || block.videoURL != nil
    }

    private static let roundOptions = [15, 20, 30, 45, 60, 90, 120, 180, 240, 300]
    private static let restOptions = [0, 10, 15, 20, 30, 40, 45, 60, 90, 120]
    private static let durationOptions = [15, 30, 45, 60, 90, 120, 180, 240, 300, 360, 480, 600, 900, 1200, 1500, 1800, 2400, 3600]

    var body: some View {
        Form {
            Section {
                TextField("Block title", text: $block.title)
                Picker("Type", selection: $block.kind) {
                    ForEach(PlanBlockKind.allCases) { Label($0.displayName, systemImage: $0.icon).tag($0) }
                }
            }

            if block.kind.isRoundBased {
                Section("Rounds") {
                    Stepper("Rounds: \(block.rounds)", value: $block.rounds, in: 1...30)
                    Picker("Work", selection: $block.workSeconds) {
                        ForEach(Self.withCurrent(Self.roundOptions, block.workSeconds), id: \.self) { Text(PlanFormat.clock($0)).tag($0) }
                    }
                    Picker("Rest", selection: $block.restSeconds) {
                        ForEach(Self.withCurrent(Self.restOptions, block.restSeconds), id: \.self) { Text(PlanFormat.clock($0)).tag($0) }
                    }
                }
            } else {
                Section(block.kind == .strength ? "Time cap" : "Duration") {
                    Picker("Duration", selection: $block.durationSeconds) {
                        ForEach(Self.withCurrent(Self.durationOptions, block.durationSeconds), id: \.self) { Text(PlanFormat.clock($0)).tag($0) }
                    }
                }
            }

            if block.kind == .strength {
                Section("Sets") {
                    Stepper("Sets: \(block.sets)", value: $block.sets, in: 1...10)
                    Stepper("Reps: \(block.reps)", value: $block.reps, in: 1...100)
                }
            }

            if block.kind == .bagRounds {
                Section {
                    Picker("Tempo", selection: $block.tempo) {
                        ForEach(BagTempo.allCases) { Text($0.displayName).tag($0) }
                    }
                    NavigationLink {
                        ComboListEditor(combos: $block.combos, stance: stance, numbers: false)
                            .navigationTitle("Allowed Combos")
                    } label: {
                        LabeledContent("Allowed combos", value: block.combos.isEmpty ? "Fighter's mix" : "\(block.combos.count)")
                    }
                } header: {
                    Text("Bag coach")
                } footer: {
                    Text("Add combos to restrict the bag coach to them, e.g. only 1-2 and low kicks. Leave empty to use the fighter's usual mix. Left and right follow each fighter's stance.")
                }
            }

            Section {
                Toggle("Show advanced settings", isOn: $showAdvanced)
            } footer: {
                Text("Heart-rate target, spoken coaching cue and technique video.")
            }

            if showAdvanced || usesAdvanced {
            Section {
                Toggle("Heart-rate target", isOn: Binding(
                    get: { block.target != nil },
                    set: { block.target = $0 ? (block.target ?? ZoneTarget(lowZone: 2, highZone: 3)) : nil }
                ))
                if let target = block.target {
                    Picker("From", selection: Binding(
                        get: { target.lowZone },
                        set: { block.target = ZoneTarget(lowZone: $0, highZone: max($0, target.highZone)) }
                    )) {
                        ForEach(1...5, id: \.self) { Text("Zone \($0)").tag($0) }
                    }
                    Picker("To", selection: Binding(
                        get: { target.highZone },
                        set: { block.target = ZoneTarget(lowZone: min(target.lowZone, $0), highZone: $0) }
                    )) {
                        ForEach(1...5, id: \.self) { Text("Zone \($0)").tag($0) }
                    }
                }
            } footer: {
                Text("Targets are zones, so each fighter's phone converts them to their own BPM.")
            }

            Section("Coaching") {
                TextField("Cue (read aloud), e.g. Snap the jab back", text: $block.cue, axis: .vertical)
                    .lineLimit(1...3)
                TextField("Technique video link (optional)", text: Binding(
                    get: { block.videoURL ?? "" },
                    set: { block.videoURL = $0.isEmpty ? nil : $0 }
                ))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                if let v = block.videoURL, !v.isEmpty, PlanBlock.safeVideoURL(v) == nil {
                    Text("Use a web link starting with https://. Other links won't open.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            }
        }
        .navigationTitle(block.title.isEmpty ? "Block" : block.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func withCurrent(_ options: [Int], _ value: Int) -> [Int] {
        options.contains(value) ? options : (options + [value]).sorted()
    }
}

/// Builds and lists combinations (used for bag-coach custom combos and plan blocks).
struct ComboListEditor: View {
    @Binding var combos: [[Strike]]
    let stance: Stance
    let numbers: Bool
    @State private var draft: [Strike] = []

    private let groups: [(String, [Strike])] = [
        ("Punches", [.jab, .cross, .leadHook, .rearHook, .leadUppercut, .rearUppercut, .leadBodyHook, .rearBodyHook]),
        ("Kicks", [.leadTeep, .rearTeep, .leadLowKick, .rearLowKick, .leadMidKick, .rearMidKick, .leadHighKick, .rearHighKick, .switchKick]),
        ("Knees & elbows", [.leadKnee, .rearKnee, .leadElbow, .rearElbow]),
        ("Defence", [.slip, .roll, .check, .pivot, .block])
    ]

    private func spoken(_ combo: [Strike]) -> String {
        combo.map { $0.callout(stance: stance, numbers: numbers).replacingOccurrences(of: "!", with: "") }.joined(separator: " → ")
    }

    var body: some View {
        List {
            Section("Build a combo") {
                if draft.isEmpty {
                    Text("Tap strikes below to build a combination.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(spoken(draft)).font(.headline)
                    HStack {
                        Button("Undo") { _ = draft.popLast() }
                        Spacer()
                        Button("Clear", role: .destructive) { draft.removeAll() }
                        Spacer()
                        Button("Add Combo") {
                            combos.append(draft)
                            draft.removeAll()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    .buttonStyle(.bordered)
                }

                ForEach(groups.indices, id: \.self) { gi in
                    let group = groups[gi]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.0).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                            ForEach(group.1) { strike in
                                Button {
                                    if draft.count < 8 { draft.append(strike) }
                                } label: {
                                    Text(strike.shortLabel(stance: stance))
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(strike.callout(stance: stance, numbers: false))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Combos") {
                if combos.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(combos.enumerated()), id: \.offset) { _, combo in
                        Text(spoken(combo)).font(.subheadline)
                    }
                    .onDelete { combos.remove(atOffsets: $0) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sharing

struct PlanShareSheet: View {
    let plan: TrainingPlan
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var copied = false

    private var link: URL? { try? PlanTransfer.link(for: plan) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let link, PlanTransfer.fitsInQRCode(link), let image = QRCode.image(for: link.absoluteString) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                            .padding(16)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("QR code for \(plan.title)")
                        Text("Your fighter scans this in FIGHT › Coach › Training Plans › Scan, or with the iPhone Camera.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Label("This plan is too big for a QR code. Send it as a file instead.", systemImage: "qrcode")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) {
                        Button {
                            fileURL = try? PlanTransfer.writePlanFile(plan)
                        } label: {
                            Label("Send as File (AirDrop, Messages, WhatsApp…)", systemImage: "doc.badge.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        if let link {
                            Button {
                                UIPasteboard.general.url = link
                                copied = true
                            } label: {
                                Label(copied ? "Link Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.large)
                }
                .padding()
            }
            .navigationTitle("Share \(plan.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { fileURL.map(ShareableFile.init) },
                set: { if $0 == nil { fileURL = nil } }
            )) { file in
                ShareSheet(items: [file.url])
            }
        }
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Scanner

struct PlanScannerSheet: View {
    @EnvironmentObject var navigation: AppNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var error: String?

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if scannerAvailable {
                    QRScannerView { value in
                        handle(value)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    Text("Point the camera at your coach's plan QR code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Label("The camera scanner isn't available on this device. Paste the plan link instead.", systemImage: "camera.metering.unknown")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Or paste a plan link").font(.headline)
                    TextField("fight://plan?d=…", text: $pasted)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Paste") { pasted = UIPasteboard.general.string ?? "" }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Open") { handle(pasted) }
                            .buttonStyle(.borderedProminent)
                            .disabled(pasted.isEmpty)
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Scan Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "That isn't a valid link."
            return
        }
        do {
            navigation.incomingPlan = try PlanTransfer.plan(fromLink: url)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var delivered = false
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue, value.hasPrefix("\(PlanTransfer.urlScheme)://") {
                    delivered = true
                    onFound(value)
                    return
                }
            }
        }
    }
}

// MARK: - Import preview

struct PlanImportSheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation
    @Environment(\.dismiss) private var dismiss
    let plan: TrainingPlan

    /// Your plan with the same ID, if any. Built-in plans (templates, plyo) never count: those
    /// IDs are reserved, so an incoming plan using one is always saved as a copy.
    private var match: TrainingPlan? { workoutStore.plans.first { $0.id == plan.id } }
    private var reservedID: Bool {
        PlyoVariant.allCases.contains { $0.planID == plan.id } || PlanTemplates.all.contains { $0.id == plan.id }
    }
    /// What gets saved when you're not replacing anything: never overwrites one of your plans.
    private var safeCopy: TrainingPlan { match != nil || reservedID ? plan.duplicated() : plan }

    var body: some View {
        let existing = match != nil
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(plan.title).font(.title3.weight(.bold))
                        if !plan.author.isEmpty {
                            Label("From \(plan.author)", systemImage: "person.fill").font(.subheadline)
                        }
                        Text("\(plan.discipline) • \(PlanFormat.totalLabel(plan.plannedSeconds)) • \(plan.blocks.count) blocks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !plan.notes.isEmpty { Text(plan.notes).font(.subheadline) }
                        if existing {
                            Label("You already have a plan called “\(match?.title ?? plan.title)” with this ID. Replace it, or keep both.", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Blocks") {
                    ForEach(plan.blocks.indices, id: \.self) { i in
                        PlanBlockRow(index: i + 1, block: plan.blocks[i], stance: workoutStore.activeProfile.bagPreferences.stance, profile: workoutStore.activeProfile)
                    }
                }
            }
            .navigationTitle("New Plan")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        let copy = safeCopy
                        workoutStore.upsertPlan(copy)
                        navigation.run(copy)
                        dismiss()
                    } label: {
                        Label("Save & Start Now", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    if let match, !reservedID {
                        Button {
                            workoutStore.upsertPlan(plan)
                            dismiss()
                        } label: {
                            Label("Replace “\(match.title)”", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button {
                        workoutStore.upsertPlan(safeCopy)
                        dismiss()
                    } label: {
                        Label(existing ? "Keep both" : "Save to My Plans", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Results from fighters

struct ResultViewerSheet: View {
    let result: SessionResultPackage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.athleteName).font(.title3.weight(.bold))
                        Text("\(result.planTitle) • \(result.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                        Text("\(result.completedBlocks)/\(result.blocks.count) blocks completed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(result.completedBlocks == result.blocks.count ? .green : .orange)
                    }
                    .padding(.vertical, 4)
                }
                Section("Summary") {
                    LabeledContent("Duration", value: PlanFormat.clock(Int(result.durationSeconds)))
                    LabeledContent("Avg / max HR", value: "\(result.averageBPM) / \(result.maxBPM) BPM")
                    LabeledContent("Load", value: "\(Int(result.load))")
                    LabeledContent("Active calories", value: "\(Int(result.activeCalories))")
                    if let rpe = result.rpe { LabeledContent("Effort (RPE)", value: "\(rpe)/10") }
                    if let score = result.reviewScore { LabeledContent("Coach review", value: "\(score)/100") }
                    if result.zoneMinutes.count == 5 {
                        LabeledContent("Zones (min)", value: result.zoneMinutes.enumerated().map { "Z\($0.offset + 1) \($0.element)" }.joined(separator: " "))
                    }
                }
                if !result.notes.isEmpty {
                    Section("Fighter's notes") { Text(result.notes) }
                }
                if !result.blocks.isEmpty {
                    Section("Blocks") {
                        ForEach(result.blocks) { BlockResultRow(result: $0) }
                    }
                }
            }
            .navigationTitle("Session Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct BlockResultRow: View {
    let result: BlockResult

    private var detailLine: String {
        var p = [PlanFormat.clock(Int(result.actualSeconds)) + " of " + PlanFormat.clock(result.plannedSeconds)]
        if let r = result.roundsCompleted { p.append("\(r) rounds") }
        if let a = result.avgBPM, let pk = result.peakBPM { p.append("avg \(a) / peak \(pk)") }
        if result.strikesCalled > 0 { p.append("\(result.strikesCalled) strikes") }
        return p.joined(separator: " • ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.completed ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(result.completed ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.subheadline.weight(.semibold))
                Text(detailLine).font(.caption).foregroundStyle(.secondary)
                if let t = result.timeInTarget, let label = result.targetLabel {
                    Text("\(Int(t * 100))% in \(label)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(t >= 0.6 ? .green : (t >= 0.4 ? .yellow : .orange))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
