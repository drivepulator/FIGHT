import Foundation
import SwiftUI

// MARK: - Biometrics & Fight Camp Models

enum BiologicalSex: String, Codable, CaseIterable, Identifiable {
    case male = "Male"
    case female = "Female"
    var id: String { rawValue }
}

enum CampPhase: String, Codable, CaseIterable, Identifiable {
    case offCamp = "Off-Camp / Base"
    case fightCamp = "Fight Camp (8-Wk)"
    case weightCut = "Weight Cut / Taper"
    case fightWeek = "Fight Week"

    var id: String { rawValue }

    var calorieAdjustment: Double {
        switch self {
        case .offCamp: return 0
        case .fightCamp: return -300
        case .weightCut: return -550
        case .fightWeek: return -750
        }
    }

    var adviceTag: String {
        switch self {
        case .offCamp: return "Build Z2 aerobic engine & strength"
        case .fightCamp: return "High glycolytic threshold & sparring"
        case .weightCut: return "Preserve power, gradual deficit"
        case .fightWeek: return "Glycogen taper & acute recovery"
        }
    }
}

enum ZoneCalculationMethod: String, Codable, CaseIterable, Identifiable {
    case karvonenHRR = "Karvonen (Heart Rate Reserve)"
    case lactateThreshold = "Lactate Threshold (LTHR %)"
    case percentMaxHR = "Standard % Max HR"
    case manual = "Custom Manual Ceilings"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .karvonenHRR: return "Uses Resting + Max HR (best for conditioned fighters)"
        case .lactateThreshold: return "Anchors Z4/Z5 directly to your 20-min LTHR test"
        case .percentMaxHR: return "Classic 60/70/80/90% of Max HR"
        case .manual: return "Set exact BPM ceilings yourself"
        }
    }
}

struct ZoneThresholds: Codable, Equatable {
    var z1Max: Int
    var z2Max: Int
    var z3Max: Int
    var z4Max: Int
}

struct HeartRateZoneInfo {
    let number: Int
    let name: String
    let shortName: String
    let color: Color
    let metValue: Double
}

struct AudioCoachSettings: Codable, Equatable {
    var masterEnabled: Bool = true
    var announceZoneCrossings: Bool = true
    var zone2CeilingAlert: Bool = true
    var announceRoundWarnings: Bool = true
    var announceStoolRecovery: Bool = true
    var periodicMinutes: Int = 2 // 0 = Off, 1, 2, 3, 5
    var announceRedlineWarning: Bool = true
    var announceGhostDelta: Bool = true
    var duckMusic: Bool = true
    var clapperWarnings: Bool = true
    var voiceVolume: Double = 1.0
    var bellVolume: Double = 0.9

    init() {}

    enum CodingKeys: String, CodingKey {
        case masterEnabled, announceZoneCrossings, zone2CeilingAlert, announceRoundWarnings, announceStoolRecovery
        case periodicMinutes, announceRedlineWarning, announceGhostDelta, duckMusic, clapperWarnings, voiceVolume, bellVolume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AudioCoachSettings()
        masterEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .masterEnabled)) ?? d.masterEnabled
        announceZoneCrossings = (try? c.decodeIfPresent(Bool.self, forKey: .announceZoneCrossings)) ?? d.announceZoneCrossings
        zone2CeilingAlert = (try? c.decodeIfPresent(Bool.self, forKey: .zone2CeilingAlert)) ?? d.zone2CeilingAlert
        announceRoundWarnings = (try? c.decodeIfPresent(Bool.self, forKey: .announceRoundWarnings)) ?? d.announceRoundWarnings
        announceStoolRecovery = (try? c.decodeIfPresent(Bool.self, forKey: .announceStoolRecovery)) ?? d.announceStoolRecovery
        periodicMinutes = (try? c.decodeIfPresent(Int.self, forKey: .periodicMinutes)) ?? d.periodicMinutes
        announceRedlineWarning = (try? c.decodeIfPresent(Bool.self, forKey: .announceRedlineWarning)) ?? d.announceRedlineWarning
        announceGhostDelta = (try? c.decodeIfPresent(Bool.self, forKey: .announceGhostDelta)) ?? d.announceGhostDelta
        duckMusic = (try? c.decodeIfPresent(Bool.self, forKey: .duckMusic)) ?? d.duckMusic
        clapperWarnings = (try? c.decodeIfPresent(Bool.self, forKey: .clapperWarnings)) ?? d.clapperWarnings
        voiceVolume = (try? c.decodeIfPresent(Double.self, forKey: .voiceVolume)) ?? d.voiceVolume
        bellVolume = (try? c.decodeIfPresent(Double.self, forKey: .bellVolume)) ?? d.bellVolume
    }
}

enum Equipment: String, Codable, CaseIterable, Identifiable {
    case jumpRope = "Jump rope"
    case heavyBag = "Heavy bag"
    case medBall = "Medicine ball"
    case plyoBox = "Plyo box"
    case band = "Resistance band"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .jumpRope: return "figure.jumprope"
        case .heavyBag: return "figure.boxing"
        case .medBall: return "circle.fill"
        case .plyoBox: return "square.stack.3d.up.fill"
        case .band: return "line.3.horizontal"
        }
    }
}

/// Plyometric experience: sets the foot-contact budget per session.
enum PlyoLevel: String, Codable, CaseIterable, Identifiable {
    case beginner = "New to it", intermediate = "Some experience", advanced = "Experienced"
    var id: String { rawValue }
    /// Upper end of the common per-session foot-contact ranges (80–100, 100–120, 120–140).
    var maxContacts: Int {
        switch self {
        case .beginner: return 100
        case .intermediate: return 120
        case .advanced: return 140
        }
    }
}

/// Which workout types and bag strikes a set of disciplines needs.
enum DisciplineRules {
    static let all = ["Muay Thai", "Kickboxing", "K-1", "Boxing", "MMA", "BJJ", "Wrestling"]

    static func categories(for disciplines: [String]) -> [WorkoutCategory] {
        var c: [WorkoutCategory] = []
        let d = Set(disciplines)
        if d.contains("Muay Thai") { c.append(.muayThai) }
        if !d.isDisjoint(with: ["Kickboxing", "K-1", "MMA"]) { c.append(.kickboxing) }
        c += [.heavyBag, .padWork, .sparring]
        if !d.isDisjoint(with: ["BJJ", "Wrestling", "MMA"]) { c.append(.bjj) }
        c += [.roadwork, .conditioning, .walk, .lthrTest]
        return c
    }

    /// Bag-coach strike sets that fit the disciplines.
    static func strikes(for disciplines: [String]) -> (kicks: Bool, kneesElbows: Bool) {
        let d = Set(disciplines)
        let kicks = !d.isDisjoint(with: ["Muay Thai", "Kickboxing", "K-1", "MMA"])
        let knees = !d.isDisjoint(with: ["Muay Thai", "K-1", "MMA"])
        return (kicks, knees)
    }
}

/// What the fighter is training for; decides what Today leads with.
enum FighterGoal: String, Codable, CaseIterable, Identifiable {
    case fight = "I have a fight coming up"
    case weight = "Make weight"
    case fitter = "Get fitter"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .fight: return "calendar.badge.exclamationmark"
        case .weight: return "scalemass"
        case .fitter: return "bolt.heart"
        }
    }
}

// MARK: - Fighter card bio

/// The fight-record details shown on the fighter card (UFC-style athlete card).
struct FighterBio: Codable, Equatable {
    enum Level: String, Codable, CaseIterable, Identifiable {
        case amateur = "Amateur", pro = "Pro"
        var id: String { rawValue }
    }

    enum Corner: String, Codable, CaseIterable, Identifiable {
        case red = "Red", blue = "Blue", gold = "Gold"
        var id: String { rawValue }
    }

    /// One weight class under a rule set. limitKg nil = no upper limit (heavyweight).
    struct WeightClass: Identifiable, Equatable {
        let name: String
        let limitKg: Double?
        var id: String { name }
    }

    /// Weight-class standards differ by sport: a K-1 middleweight is 75 kg, a UFC one 83.9 kg.
    enum WeightRules: String, Codable, CaseIterable, Identifiable {
        case mma = "MMA (Unified)"
        case boxing = "Boxing"
        case muayThai = "Muay Thai (WBC)"
        case k1 = "K-1"
        case glory = "GLORY Kickboxing"
        var id: String { rawValue }

        private static let boxingClasses: [WeightClass] = [
            .init(name: "Minimumweight", limitKg: 47.6), .init(name: "Light Flyweight", limitKg: 49.0),
            .init(name: "Flyweight", limitKg: 50.8), .init(name: "Super Flyweight", limitKg: 52.2),
            .init(name: "Bantamweight", limitKg: 53.5), .init(name: "Super Bantamweight", limitKg: 55.3),
            .init(name: "Featherweight", limitKg: 57.2), .init(name: "Super Featherweight", limitKg: 59.0),
            .init(name: "Lightweight", limitKg: 61.2), .init(name: "Super Lightweight", limitKg: 63.5),
            .init(name: "Welterweight", limitKg: 66.7), .init(name: "Super Welterweight", limitKg: 69.9),
            .init(name: "Middleweight", limitKg: 72.6), .init(name: "Super Middleweight", limitKg: 76.2),
            .init(name: "Light Heavyweight", limitKg: 79.4), .init(name: "Cruiserweight", limitKg: 90.7),
            .init(name: "Heavyweight", limitKg: nil)
        ]

        var classes: [WeightClass] {
            switch self {
            case .mma:
                return [
                    .init(name: "Strawweight", limitKg: 52.2), .init(name: "Flyweight", limitKg: 56.7),
                    .init(name: "Bantamweight", limitKg: 61.2), .init(name: "Featherweight", limitKg: 65.8),
                    .init(name: "Lightweight", limitKg: 70.3), .init(name: "Welterweight", limitKg: 77.1),
                    .init(name: "Middleweight", limitKg: 83.9), .init(name: "Light Heavyweight", limitKg: 93.0),
                    .init(name: "Heavyweight", limitKg: 120.2)
                ]
            case .boxing, .muayThai:
                return Self.boxingClasses
            case .k1:
                return [
                    .init(name: "Flyweight", limitKg: 52), .init(name: "Super Bantamweight", limitKg: 55),
                    .init(name: "Featherweight", limitKg: 57.5), .init(name: "Super Featherweight", limitKg: 60),
                    .init(name: "Lightweight", limitKg: 62.5), .init(name: "Super Lightweight", limitKg: 65),
                    .init(name: "Welterweight", limitKg: 67.5), .init(name: "Super Welterweight", limitKg: 70),
                    .init(name: "Middleweight", limitKg: 75), .init(name: "Cruiserweight", limitKg: 90),
                    .init(name: "Heavyweight", limitKg: nil)
                ]
            case .glory:
                return [
                    .init(name: "Featherweight", limitKg: 65), .init(name: "Lightweight", limitKg: 70),
                    .init(name: "Welterweight", limitKg: 77), .init(name: "Middleweight", limitKg: 85),
                    .init(name: "Light Heavyweight", limitKg: 95), .init(name: "Heavyweight", limitKg: nil)
                ]
            }
        }

        /// The usual standard for a discipline.
        static func forDiscipline(_ d: String) -> WeightRules {
            switch d {
            case "MMA", "BJJ", "Wrestling": return .mma
            case "Boxing": return .boxing
            case "Muay Thai": return .muayThai
            case "K-1": return .k1
            case "Kickboxing": return .glory
            default: return .k1
            }
        }

        /// The lightest class a fight weight fits into.
        func suggested(forKg kg: Double) -> WeightClass {
            classes.first { ($0.limitKg ?? .infinity) + 0.05 >= kg } ?? classes[classes.count - 1]
        }

        func weightClass(named name: String?) -> WeightClass? {
            classes.first { $0.name == name }
        }

        /// "70.3 kg", or "+90.7 kg" for an unlimited class.
        func limitText(_ c: WeightClass, imperial: Bool) -> String {
            if let l = c.limitKg { return WeightUnits.text(l, imperial) }
            let prev = classes.compactMap(\.limitKg).max() ?? 0
            return "+" + WeightUnits.text(prev, imperial)
        }
    }

    var nickname = ""
    var level: Level = .amateur
    var wins = 0
    var losses = 0
    var draws = 0
    var finishes = 0
    /// nil = the usual standard for the discipline.
    var rules: WeightRules?
    /// Chosen class name under the rules; nil = suggest from the fight-weight target.
    var divisionName: String?
    var reachCm: Double?
    var gym = ""
    /// ISO region code, e.g. "IL", "GB".
    var country = ""
    var discipline = "Kickboxing"
    var corner: Corner = .red
    var showFightFitness = true
    var showGasTank = true
    var showBestRecovery = true

    var effectiveRules: WeightRules { rules ?? .forDiscipline(discipline) }

    /// The chosen class, or the one the fight weight fits.
    func weightClass(fightWeightKg: Double) -> WeightClass {
        effectiveRules.weightClass(named: divisionName) ?? effectiveRules.suggested(forKg: fightWeightKg)
    }

    var record: String { "\(wins)-\(losses)-\(draws)" }

    /// e.g. "5 by KO / TKO" when there are finishes.
    var finishesText: String? { finishes > 0 ? "\(min(finishes, wins)) by KO / TKO" : nil }

    /// Flag emoji from a two-letter region code.
    static func flag(_ code: String) -> String {
        let up = code.uppercased()
        guard up.count == 2, up.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "" }
        return String(String.UnicodeScalarView(up.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nickname = (try? c.decodeIfPresent(String.self, forKey: .nickname)) ?? ""
        level = (try? c.decodeIfPresent(Level.self, forKey: .level)) ?? .amateur
        wins = (try? c.decodeIfPresent(Int.self, forKey: .wins)) ?? 0
        losses = (try? c.decodeIfPresent(Int.self, forKey: .losses)) ?? 0
        draws = (try? c.decodeIfPresent(Int.self, forKey: .draws)) ?? 0
        finishes = (try? c.decodeIfPresent(Int.self, forKey: .finishes)) ?? 0
        rules = try? c.decodeIfPresent(WeightRules.self, forKey: .rules)
        divisionName = (try? c.decodeIfPresent(String.self, forKey: .divisionName)) ?? nil
        reachCm = try? c.decodeIfPresent(Double.self, forKey: .reachCm)
        gym = (try? c.decodeIfPresent(String.self, forKey: .gym)) ?? ""
        country = (try? c.decodeIfPresent(String.self, forKey: .country)) ?? ""
        discipline = (try? c.decodeIfPresent(String.self, forKey: .discipline)) ?? "Kickboxing"
        corner = (try? c.decodeIfPresent(Corner.self, forKey: .corner)) ?? .red
        showFightFitness = (try? c.decodeIfPresent(Bool.self, forKey: .showFightFitness)) ?? true
        showGasTank = (try? c.decodeIfPresent(Bool.self, forKey: .showGasTank)) ?? true
        showBestRecovery = (try? c.decodeIfPresent(Bool.self, forKey: .showBestRecovery)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case nickname, level, wins, losses, draws, finishes, rules, divisionName, reachCm, gym, country, discipline
        case corner, showFightFitness, showGasTank, showBestRecovery
    }
}

struct AthleteProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Fighter"
    var sex: BiologicalSex = .male
    var age: Int = 20
    var weightKg: Double = 90.0
    var heightCm: Double = 184.0
    var targetFightWeightKg: Double = 84.0
    var restingHR: Int = 56
    var useAutoMaxHR: Bool = true
    var maxHR: Int = 194
    var lactateThresholdHR: Int = 174
    var zoneMethod: ZoneCalculationMethod = .karvonenHRR
    var manualZones: ZoneThresholds = ZoneThresholds(z1Max: 125, z2Max: 145, z3Max: 162, z4Max: 178)
    var campPhase: CampPhase = .fightCamp
    var audioCoach: AudioCoachSettings = AudioCoachSettings()
    var fightDate: Date? = nil
    var campLengthWeeks: Int = 8
    var bagPreferences = BagPreferences()
    /// Weight shown in pounds (stored in kg either way).
    var useImperial = Locale.current.measurementSystem == .us
    /// Height shown in feet and inches (stored in cm either way).
    var heightImperial = Locale.current.measurementSystem == .us
    var campHistory: [CampRecord] = []
    var trackHeadMovement = true
    var guidedBreathing = false
    var bio = FighterBio()
    /// Finished the first-run setup.
    var setupDone = false
    var goal: FighterGoal = .fitter
    /// Rounds and minutes of the fight format the fighter trains for (Gas Tank target, default timer).
    var formatRounds = 3
    var formatMinutes = 3
    /// AirPods extras.
    var headCues = true
    var nodToStart = true
    /// Count bag hits with the phone microphone during bag work.
    var countBagHits = false
    /// What the fighter trains; the first is the main discipline. Hides irrelevant options.
    var disciplines: [String] = []
    /// Gear the fighter owns (checked again before each plyo session).
    var equipment: [Equipment] = [.jumpRope, .heavyBag]
    var plyoLevel: PlyoLevel = .intermediate
    /// The coach pushes you when you slow down and calms you when you redline.
    var encouragement = true

    /// Disciplines to use: the chosen list, or the card's discipline.
    var trainedDisciplines: [String] { disciplines.isEmpty ? [bio.discipline] : disciplines }

    /// Sets what the fighter trains (first = main) and fits the bag-coach strikes to it.
    mutating func setDisciplines(_ list: [String]) {
        disciplines = list.isEmpty ? [bio.discipline] : list
        bio.discipline = disciplines[0]
        let strikes = DisciplineRules.strikes(for: disciplines)
        bagPreferences.includeKicks = strikes.kicks
        bagPreferences.includeKneesElbows = strikes.kneesElbows
    }

    var fightFormat: FightFormat { FightFormat(rounds: formatRounds, minutes: formatMinutes) }

    enum CodingKeys: String, CodingKey {
        case id, name, sex, age, weightKg, heightCm, targetFightWeightKg
        case restingHR, useAutoMaxHR, maxHR, lactateThresholdHR, zoneMethod
        case manualZones, campPhase, audioCoach
        case fightDate, campLengthWeeks, bagPreferences, useImperial
        case campHistory, trackHeadMovement, guidedBreathing, heightImperial, bio
        case setupDone, goal, formatRounds, formatMinutes, headCues, nodToStart, countBagHits
        case disciplines, equipment, plyoLevel, encouragement
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Fighter"
        sex = try c.decodeIfPresent(BiologicalSex.self, forKey: .sex) ?? .male
        age = try c.decodeIfPresent(Int.self, forKey: .age) ?? 20
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg) ?? 90.0
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm) ?? 184.0
        targetFightWeightKg = try c.decodeIfPresent(Double.self, forKey: .targetFightWeightKg) ?? 84.0
        restingHR = try c.decodeIfPresent(Int.self, forKey: .restingHR) ?? 56
        useAutoMaxHR = try c.decodeIfPresent(Bool.self, forKey: .useAutoMaxHR) ?? true
        maxHR = try c.decodeIfPresent(Int.self, forKey: .maxHR) ?? 194
        lactateThresholdHR = try c.decodeIfPresent(Int.self, forKey: .lactateThresholdHR) ?? 174
        zoneMethod = try c.decodeIfPresent(ZoneCalculationMethod.self, forKey: .zoneMethod) ?? .karvonenHRR
        manualZones = try c.decodeIfPresent(ZoneThresholds.self, forKey: .manualZones) ?? ZoneThresholds(z1Max: 125, z2Max: 145, z3Max: 162, z4Max: 178)
        campPhase = try c.decodeIfPresent(CampPhase.self, forKey: .campPhase) ?? .fightCamp
        audioCoach = (try? c.decodeIfPresent(AudioCoachSettings.self, forKey: .audioCoach)) ?? AudioCoachSettings()
        fightDate = try c.decodeIfPresent(Date.self, forKey: .fightDate)
        campLengthWeeks = try c.decodeIfPresent(Int.self, forKey: .campLengthWeeks) ?? 8
        bagPreferences = (try? c.decodeIfPresent(BagPreferences.self, forKey: .bagPreferences)) ?? BagPreferences()
        useImperial = (try? c.decodeIfPresent(Bool.self, forKey: .useImperial)) ?? false
        heightImperial = (try? c.decodeIfPresent(Bool.self, forKey: .heightImperial)) ?? useImperial
        bio = (try? c.decodeIfPresent(FighterBio.self, forKey: .bio)) ?? FighterBio()
        setupDone = (try? c.decodeIfPresent(Bool.self, forKey: .setupDone)) ?? false
        goal = (try? c.decodeIfPresent(FighterGoal.self, forKey: .goal)) ?? (fightDate != nil ? .fight : .fitter)
        formatRounds = (try? c.decodeIfPresent(Int.self, forKey: .formatRounds)) ?? 3
        formatMinutes = (try? c.decodeIfPresent(Int.self, forKey: .formatMinutes)) ?? 3
        headCues = (try? c.decodeIfPresent(Bool.self, forKey: .headCues)) ?? true
        nodToStart = (try? c.decodeIfPresent(Bool.self, forKey: .nodToStart)) ?? true
        countBagHits = (try? c.decodeIfPresent(Bool.self, forKey: .countBagHits)) ?? false
        disciplines = (try? c.decodeIfPresent([String].self, forKey: .disciplines)) ?? []
        equipment = (try? c.decodeIfPresent([Equipment].self, forKey: .equipment)) ?? [.jumpRope, .heavyBag]
        plyoLevel = (try? c.decodeIfPresent(PlyoLevel.self, forKey: .plyoLevel)) ?? .intermediate
        encouragement = (try? c.decodeIfPresent(Bool.self, forKey: .encouragement)) ?? true
        campHistory = (try? c.decodeIfPresent([CampRecord].self, forKey: .campHistory)) ?? []
        trackHeadMovement = (try? c.decodeIfPresent(Bool.self, forKey: .trackHeadMovement)) ?? true
        guidedBreathing = (try? c.decodeIfPresent(Bool.self, forKey: .guidedBreathing)) ?? false
    }

    mutating func sanitize() {
        age = min(max(age, 13), 85)
        weightKg = min(max(weightKg, 35.0), 200.0)
        heightCm = min(max(heightCm, 120.0), 240.0)
        targetFightWeightKg = min(max(targetFightWeightKg, 35.0), 200.0)
        restingHR = min(max(restingHR, 30), 110)
        campLengthWeeks = min(max(campLengthWeeks, 4), 16)
        let tanaka = Int(round(208.0 - 0.7 * Double(age)))
        if useAutoMaxHR {
            maxHR = tanaka
        } else {
            maxHR = min(max(maxHR, restingHR + 35), 230)
        }
        lactateThresholdHR = min(max(lactateThresholdHR, restingHR + 25), max(restingHR + 25, maxHR - 3))
        manualZones.z1Max = min(max(manualZones.z1Max, 80), maxHR - 35)
        manualZones.z2Max = min(max(manualZones.z2Max, manualZones.z1Max + 5), maxHR - 25)
        manualZones.z3Max = min(max(manualZones.z3Max, manualZones.z2Max + 5), maxHR - 15)
        manualZones.z4Max = min(max(manualZones.z4Max, manualZones.z3Max + 5), maxHR - 5)
    }

    var effectiveMaxHR: Int {
        if useAutoMaxHR {
            return Int(round(208.0 - 0.7 * Double(age)))
        }
        return max(restingHR + 35, maxHR)
    }

    var activeZones: ZoneThresholds {
        let maxH = Double(effectiveMaxHR)
        let restH = Double(restingHR)
        let hrr = max(35.0, maxH - restH)

        switch zoneMethod {
        case .karvonenHRR:
            return ZoneThresholds(
                z1Max: Int(round(restH + hrr * 0.60)),
                z2Max: Int(round(restH + hrr * 0.70)),
                z3Max: Int(round(restH + hrr * 0.80)),
                z4Max: Int(round(restH + hrr * 0.90))
            )
        case .lactateThreshold:
            let lt = Double(lactateThresholdHR)
            return ZoneThresholds(
                z1Max: Int(round(lt * 0.81)),
                z2Max: Int(round(lt * 0.89)),
                z3Max: Int(round(lt * 0.95)),
                z4Max: Int(round(lt * 1.00))
            )
        case .percentMaxHR:
            return ZoneThresholds(
                z1Max: Int(round(maxH * 0.60)),
                z2Max: Int(round(maxH * 0.70)),
                z3Max: Int(round(maxH * 0.80)),
                z4Max: Int(round(maxH * 0.90))
            )
        case .manual:
            return manualZones
        }
    }

    func zone(for bpm: Int) -> HeartRateZoneInfo {
        let z = activeZones
        if bpm <= z.z1Max {
            return HeartRateZoneInfo(number: 1, name: "Zone 1 • Recovery", shortName: "Z1", color: .blue, metValue: 3.5)
        } else if bpm <= z.z2Max {
            return HeartRateZoneInfo(number: 2, name: "Zone 2 • Aerobic Base", shortName: "Z2", color: .green, metValue: 6.5)
        } else if bpm <= z.z3Max {
            return HeartRateZoneInfo(number: 3, name: "Zone 3 • Tempo", shortName: "Z3", color: .yellow, metValue: 8.8)
        } else if bpm <= z.z4Max {
            return HeartRateZoneInfo(number: 4, name: "Zone 4 • Threshold", shortName: "Z4", color: .orange, metValue: 11.2)
        } else {
            return HeartRateZoneInfo(number: 5, name: "Zone 5 • Anaerobic Peak", shortName: "Z5", color: .red, metValue: 13.5)
        }
    }

    var bmrCaloriesPerDay: Double {
        let base = (10.0 * weightKg) + (6.25 * heightCm) - (5.0 * Double(age))
        return sex == .male ? (base + 5.0) : (base - 161.0)
    }

    var bmrCaloriesPerMinute: Double {
        max(0.8, bmrCaloriesPerDay / 1440.0)
    }

    var dailyCalorieTarget: Int {
        let maintenance = bmrCaloriesPerDay * 1.55
        return max(1400, Int(round(maintenance + campPhase.calorieAdjustment)))
    }

    var weightDeltaKg: Double {
        weightKg - targetFightWeightKg
    }
}

// MARK: - Workout Disciplines & Drills

enum WorkoutCategory: String, Codable, CaseIterable, Identifiable {
    case muayThai = "Muay Thai"
    case kickboxing = "Kickboxing"
    case heavyBag = "Heavy Bag"
    case padWork = "Pad Work"
    case sparring = "Sparring"
    case bjj = "BJJ / Grappling"
    case roadwork = "Roadwork / Run"
    case walk = "Walk / Active Recovery"
    case conditioning = "S&C / Conditioning"
    case lthrTest = "20-Min LTHR Field Test"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .muayThai: return "figure.kickboxing"
        case .kickboxing: return "figure.martial.arts"
        case .heavyBag: return "figure.boxing"
        case .padWork: return "hand.raised.fingers.spread.fill"
        case .sparring: return "shield.lefthalf.filled"
        case .bjj: return "figure.wrestling"
        case .roadwork: return "figure.run"
        case .walk: return "figure.walk"
        case .conditioning: return "dumbbell.fill"
        case .lthrTest: return "waveform.path.ecg"
        }
    }

    // MARK: What each workout type is (one place decides what the app shows for it)

    /// GPS runs and walks: distance, pace and splits. No rounds, combos or technique tags.
    var isRun: Bool { self == .roadwork || self == .walk }
    /// Striking sessions where the voice bag coach makes sense.
    var allowsBagCoach: Bool { [.muayThai, .kickboxing, .heavyBag, .padWork].contains(self) }
    /// A round bell and rest timer make sense.
    var allowsRounds: Bool { self != .walk && self != .lthrTest }   // roadwork: fight-round runs and sprints
    /// Step-by-step plans (they carry their own blocks).
    var allowsPlans: Bool { !isRun && self != .lthrTest }
    /// Racing a past session's heart rate.
    var allowsGhost: Bool { !isRun && self != .lthrTest }
    /// "Who did you spar / roll with?" and round results.
    var hasPartner: Bool { self == .sparring || self == .bjj }

    /// What the session was for, only the choices that fit this workout type.
    var drillTags: [DrillTag] {
        switch self {
        case .roadwork, .walk: return [.aerobicZ2, .intervals]
        case .lthrTest: return [.lthrProtocol]
        case .sparring: return [.hardSparring, .technical, .sharkTank]
        case .bjj: return [.technical, .hardSparring, .sharkTank]
        case .conditioning: return [.intervals, .aerobicZ2]
        case .heavyBag: return [.bagWork, .technical, .intervals]
        case .muayThai, .kickboxing, .padWork: return [.technical, .bagWork, .intervals]
        }
    }

    var defaultDrill: DrillTag { drillTags[0] }

    /// Technique tags for "What did you work on?" (empty: the question isn't asked).
    func focusOptions(disciplines: [String]) -> [String] {
        let strikes = DisciplineRules.strikes(for: disciplines)
        var striking = ["Jab", "Cross", "Hooks", "Uppercuts", "Body shots"]
        if strikes.kicks { striking += ["Low kicks", "Body kicks", "Head kicks", "Teeps"] }
        if strikes.kneesElbows { striking += ["Knees", "Elbows", "Clinch"] }
        striking += ["Defence", "Footwork", "Counters"]
        let grappling = ["Takedowns", "Guard", "Passing", "Escapes", "Submissions", "Ground"]
        switch self {
        case .muayThai, .kickboxing, .heavyBag, .padWork: return striking
        case .sparring:
            let grapples = !Set(disciplines).isDisjoint(with: ["MMA", "BJJ", "Wrestling"])
            return striking + (grapples ? grappling : [])
        case .bjj: return grappling + ["Clinch"]
        case .roadwork, .walk, .conditioning, .lthrTest: return []
        }
    }

    var usesRoundTimerByDefault: Bool {
        switch self {
        case .muayThai, .kickboxing, .heavyBag, .padWork, .sparring, .bjj:
            return true
        case .roadwork, .walk, .conditioning, .lthrTest:
            return false
        }
    }

    var defaultWorkSeconds: Int {
        switch self {
        case .bjj: return 300
        case .muayThai, .kickboxing, .heavyBag, .padWork, .sparring: return 180
        case .conditioning: return 45
        case .roadwork, .walk, .lthrTest: return 180
        }
    }

    var defaultRestSeconds: Int {
        switch self {
        case .conditioning: return 15
        default: return 60
        }
    }

    var timerModeHint: String {
        switch self {
        case .walk, .roadwork:
            return "Continuous tracking (optional intervals)"
        case .lthrTest:
            return "10m Warm-Up + 20m All-Out LTHR Trial"
        case .bjj:
            return "Default 5:00 roll × 1:00 rest"
        default:
            return "Default 3:00 round × 1:00 stool rest"
        }
    }
}

enum DrillTag: String, Codable, CaseIterable, Identifiable {
    case technical = "Technical"
    case aerobicZ2 = "Aerobic Z2"
    case bagWork = "Bag Work"
    case intervals = "HIIT / Tabata"
    case hardSparring = "Hard Sparring"
    case sharkTank = "Shark Tank"
    case lthrProtocol = "LTHR Protocol"

    var id: String { rawValue }

    /// Plain words for the picker, in the context of the workout type.
    func label(for category: WorkoutCategory) -> String {
        switch self {
        case .aerobicZ2: return category.isRun ? "Easy (Zone 2)" : "Easy aerobic"
        case .intervals: return category.isRun ? "Intervals / tempo" : "Hard intervals"
        case .technical: return "Technique"
        case .bagWork: return "Hard bag rounds"
        case .hardSparring: return "Hard sparring"
        case .sharkTank: return "Shark tank"
        case .lthrProtocol: return "Threshold test"
        }
    }
}

// MARK: - Telemetry & Analytics Models

struct HeartRatePoint: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let elapsedSeconds: TimeInterval
    let bpm: Int
    let rrIntervalsMs: [Double]

    init(id: UUID = UUID(), timestamp: Date = Date(), elapsedSeconds: TimeInterval, bpm: Int, rrIntervalsMs: [Double] = []) {
        self.id = id
        self.timestamp = timestamp
        self.elapsedSeconds = elapsedSeconds
        self.bpm = bpm
        self.rrIntervalsMs = rrIntervalsMs
    }

    // Compact storage: about a tenth of the old size. No per-sample id on disk, the time as a
    // number instead of a date string, RR rounded to 0.1 ms (sensors measure in ~1 ms steps).
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, elapsedSeconds, bpm, rrIntervalsMs   // old format
        case e, b, s, r                                          // compact format
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let b = try c.decodeIfPresent(Int.self, forKey: .b) {
            id = UUID()
            bpm = b
            elapsedSeconds = try c.decode(Double.self, forKey: .e)
            timestamp = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .s))
            rrIntervalsMs = try c.decodeIfPresent([Double].self, forKey: .r) ?? []
        } else {
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            elapsedSeconds = try c.decode(Double.self, forKey: .elapsedSeconds)
            bpm = try c.decode(Int.self, forKey: .bpm)
            rrIntervalsMs = try c.decodeIfPresent([Double].self, forKey: .rrIntervalsMs) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bpm, forKey: .b)
        try c.encode((elapsedSeconds * 100).rounded() / 100, forKey: .e)
        try c.encode((timestamp.timeIntervalSinceReferenceDate * 100).rounded() / 100, forKey: .s)
        if !rrIntervalsMs.isEmpty {
            try c.encode(rrIntervalsMs.map { ($0 * 10).rounded() / 10 }, forKey: .r)
        }
    }
}

struct RoundStat: Codable, Identifiable, Equatable {
    let id: UUID
    let roundNumber: Int
    let startElapsed: TimeInterval
    let endElapsed: TimeInterval
    let avgBPM: Int
    let peakBPM: Int
    let stoolDropBPM: Int?
    let strikesCued: Int
    /// Head movements detected by AirPods during the round (nil = not tracked).
    var headMoves: Int?
    /// Seconds the chin was lifted (AirPods), nil = not tracked.
    var chinUpSeconds: Int?
    /// Footwork bounces counted by AirPods, nil = not tracked.
    var bounces: Int?
    /// Bag hits heard by the microphone, nil = not counted.
    var impacts: Int?

    enum CodingKeys: String, CodingKey {
        case id, roundNumber, startElapsed, endElapsed, avgBPM, peakBPM, stoolDropBPM, strikesCued, headMoves
        case chinUpSeconds, bounces, impacts
    }

    init(id: UUID = UUID(), roundNumber: Int, startElapsed: TimeInterval, endElapsed: TimeInterval, avgBPM: Int, peakBPM: Int, stoolDropBPM: Int?, strikesCued: Int = 0, headMoves: Int? = nil,
         chinUpSeconds: Int? = nil, bounces: Int? = nil, impacts: Int? = nil) {
        self.chinUpSeconds = chinUpSeconds
        self.bounces = bounces
        self.impacts = impacts
        self.id = id
        self.roundNumber = roundNumber
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.avgBPM = avgBPM
        self.peakBPM = peakBPM
        self.stoolDropBPM = stoolDropBPM
        self.strikesCued = strikesCued
        self.headMoves = headMoves
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        roundNumber = try c.decode(Int.self, forKey: .roundNumber)
        startElapsed = try c.decode(TimeInterval.self, forKey: .startElapsed)
        endElapsed = try c.decode(TimeInterval.self, forKey: .endElapsed)
        avgBPM = try c.decode(Int.self, forKey: .avgBPM)
        peakBPM = try c.decode(Int.self, forKey: .peakBPM)
        stoolDropBPM = try c.decodeIfPresent(Int.self, forKey: .stoolDropBPM)
        strikesCued = try c.decodeIfPresent(Int.self, forKey: .strikesCued) ?? 0
        headMoves = try? c.decodeIfPresent(Int.self, forKey: .headMoves)
        chinUpSeconds = try? c.decodeIfPresent(Int.self, forKey: .chinUpSeconds)
        bounces = try? c.decodeIfPresent(Int.self, forKey: .bounces)
        impacts = try? c.decodeIfPresent(Int.self, forKey: .impacts)
    }
}

/// One combination the bag coach called, and when (seconds into the workout).
struct ComboEvent: Codable, Equatable {
    var t: TimeInterval
    var strikes: [Strike]
}

/// A finished fight camp, kept so the next camp can be compared to it.
struct CampRecord: Codable, Equatable, Hashable {
    var fightDate: Date
    var campLengthWeeks: Int
}

/// Body areas for the soreness log.
enum BodyRegion: String, Codable, CaseIterable, Identifiable {
    case neck = "Neck", shoulder = "Shoulder", elbow = "Elbow", wrist = "Wrist / hand"
    case ribs = "Ribs", lowerBack = "Lower back", hip = "Hip / groin"
    case knee = "Knee", shin = "Shin", ankle = "Ankle / foot"
    var id: String { rawValue }

    var isKickingArea: Bool { self == .shin || self == .ankle || self == .knee || self == .hip }
    var isPunchingArea: Bool { self == .wrist || self == .elbow || self == .shoulder }
}

struct SorenessEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var profileID: UUID
    var date = Date()
    var region: BodyRegion
    /// 1 = niggle, 2 = sore, 3 = painful
    var severity: Int
    var note: String = ""
}

struct AutoHRREvent: Codable, Identifiable, Equatable {
    let id: UUID
    let elapsedSeconds: TimeInterval
    let peakBPM: Int
    let recovery60BPM: Int
    let dropBPM: Int
    let contextLabel: String

    init(id: UUID = UUID(), elapsedSeconds: TimeInterval, peakBPM: Int, recovery60BPM: Int, dropBPM: Int, contextLabel: String) {
        self.id = id
        self.elapsedSeconds = elapsedSeconds
        self.peakBPM = peakBPM
        self.recovery60BPM = recovery60BPM
        self.dropBPM = dropBPM
        self.contextLabel = contextLabel
    }
}

struct WorkoutPOI: Codable, Identifiable, Equatable {
    let id: UUID
    let elapsedSeconds: TimeInterval
    let bpm: Int
    let shortTag: String
    let title: String
    let detail: String
    let symbol: String
    let isPositive: Bool

    enum CodingKeys: String, CodingKey {
        case id, elapsedSeconds, bpm, shortTag, title, detail, symbol, isPositive
    }

    init(id: UUID = UUID(), elapsedSeconds: TimeInterval, bpm: Int, shortTag: String = "POI", title: String, detail: String, symbol: String, isPositive: Bool) {
        self.id = id
        self.elapsedSeconds = elapsedSeconds
        self.bpm = bpm
        self.shortTag = shortTag
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.isPositive = isPositive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        elapsedSeconds = try c.decode(TimeInterval.self, forKey: .elapsedSeconds)
        bpm = try c.decode(Int.self, forKey: .bpm)
        title = try c.decode(String.self, forKey: .title)
        shortTag = try c.decodeIfPresent(String.self, forKey: .shortTag) ?? String(title.prefix(12))
        detail = try c.decode(String.self, forKey: .detail)
        symbol = try c.decode(String.self, forKey: .symbol)
        isPositive = try c.decode(Bool.self, forKey: .isPositive)
    }
}

struct GhostSession: Identifiable, Equatable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String
    let samples: [HeartRatePoint]
    let roundStats: [RoundStat]
    let avgBPM: Int
    let peakBPM: Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func interpolatedBPM(at elapsed: TimeInterval) -> Int? {
        guard !samples.isEmpty else { return nil }
        if elapsed <= samples.first!.elapsedSeconds { return samples.first!.bpm }
        if elapsed >= samples.last!.elapsedSeconds { return nil }
        // Binary search for the first sample at or after `elapsed`.
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].elapsedSeconds < elapsed { lo = mid + 1 } else { hi = mid }
        }
        if samples[lo].elapsedSeconds >= elapsed {
            let idx = lo
            if idx == 0 { return samples[0].bpm }
            let prev = samples[idx - 1]
            let next = samples[idx]
            let span = max(0.001, next.elapsedSeconds - prev.elapsedSeconds)
            let ratio = (elapsed - prev.elapsedSeconds) / span
            return Int(round(Double(prev.bpm) + ratio * Double(next.bpm - prev.bpm)))
        }
        return nil
    }
}

struct SavedWorkout: Codable, Identifiable {
    let id: UUID
    let profileID: UUID
    let profileName: String
    let category: WorkoutCategory
    let drillTag: DrillTag
    var rpe: Int
    var notes: String
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let averageBPM: Int
    let maxBPM: Int
    let minBPM: Int
    var activeCalories: Double
    let bmrCalories: Double
    var calories: Double
    let epocBonusCalories: Double
    let trimpScore: Double
    let cardiacDriftPercent: Double
    let hrr60Drop: Int?
    let autoHRREvents: [AutoHRREvent]
    let rmssdMs: Double?
    let strikesCuedCount: Int
    let ghostBaselineName: String?
    let ghostAvgDeltaBPM: Double?
    let zoneSeconds: [Int: TimeInterval]
    let roundStats: [RoundStat]
    let pointsOfInterest: [WorkoutPOI]
    var samples: [HeartRatePoint]
    var isCompressedArchive: Bool
    var archiveFileName: String?
    var rpeRated: Bool = false
    var planTitle: String?
    var planTargetLow: Int?
    var planTargetHigh: Int?
    var planAdherence: Double?
    var trainingPlanID: UUID?
    var trainingPlanTitle: String?
    var blockResults: [BlockResult] = []
    var comboEvents: [ComboEvent] = []
    var headMovesPerMinute: Double?
    var breathingGuided = false
    /// Rounds were found from the heart-rate pattern (no round timer used).
    var roundsAutoDetected = false
    /// What the fighter worked on, e.g. ["Jab", "Defence"].
    var focusTags: [String] = []
    /// Sparring partner's name.
    var partner: String?
    /// Per-round self-scoring: "W", "E" (even) or "L".
    var roundResults: [String] = []
    /// Total bag hits heard by the microphone.
    var impactsCount: Int?
    /// Set when moved to Recently Deleted (kept 30 days).
    var deletedAt: Date?
    /// Jump heights measured by AirPods (cm).
    var jumps: [Double] = []
    /// GPS run: distance, splits, moving time (the route lives in its own file).
    var run: RunSummary?
    /// What it was in the fighter's words, e.g. "Muay Thai · Bag work" (nil on older sessions).
    var activityName: String?
    /// Heart rate estimated while the strap was off. Never part of the averages, zones or records.
    var estimatedSamples: [HeartRatePoint] = []
    /// Estimated burn while the strap was off. Not included in `calories`.
    var estimatedCalories: Double = 0
    /// Seconds of real heart rate recovered from a FIGHT Logger after the phone dropped out.
    var recoveredFromLogger: Int = 0
    /// Seconds covered by estimates.
    var estimatedSeconds: TimeInterval { Double(estimatedSamples.count) }

    /// The name to show for this session.
    var displayTitle: String { activityName ?? category.rawValue }

    enum CodingKeys: String, CodingKey {
        case id, profileID, profileName, category, drillTag, rpe, notes
        case startDate, endDate, duration, averageBPM, maxBPM, minBPM
        case activeCalories, bmrCalories, calories, epocBonusCalories
        case trimpScore, cardiacDriftPercent, hrr60Drop, autoHRREvents
        case rmssdMs, strikesCuedCount, ghostBaselineName, ghostAvgDeltaBPM
        case zoneSeconds, roundStats, pointsOfInterest, samples
        case isCompressedArchive, archiveFileName
        case rpeRated, planTitle, planTargetLow, planTargetHigh, planAdherence
        case trainingPlanID, trainingPlanTitle, blockResults
        case comboEvents, headMovesPerMinute, breathingGuided
        case roundsAutoDetected, focusTags, partner, roundResults, impactsCount, deletedAt, jumps, run, activityName
        case estimatedSamples, estimatedCalories, recoveredFromLogger
    }

    init(
        id: UUID,
        profileID: UUID,
        profileName: String,
        category: WorkoutCategory,
        drillTag: DrillTag,
        rpe: Int,
        notes: String,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        averageBPM: Int,
        maxBPM: Int,
        minBPM: Int,
        activeCalories: Double,
        bmrCalories: Double,
        calories: Double,
        epocBonusCalories: Double,
        trimpScore: Double,
        cardiacDriftPercent: Double,
        hrr60Drop: Int?,
        autoHRREvents: [AutoHRREvent],
        rmssdMs: Double?,
        strikesCuedCount: Int,
        ghostBaselineName: String?,
        ghostAvgDeltaBPM: Double?,
        zoneSeconds: [Int: TimeInterval],
        roundStats: [RoundStat],
        pointsOfInterest: [WorkoutPOI],
        samples: [HeartRatePoint],
        isCompressedArchive: Bool,
        archiveFileName: String?,
        rpeRated: Bool = false,
        planTitle: String? = nil,
        planTargetLow: Int? = nil,
        planTargetHigh: Int? = nil,
        planAdherence: Double? = nil,
        trainingPlanID: UUID? = nil,
        trainingPlanTitle: String? = nil,
        blockResults: [BlockResult] = [],
        comboEvents: [ComboEvent] = [],
        headMovesPerMinute: Double? = nil,
        breathingGuided: Bool = false
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.category = category
        self.drillTag = drillTag
        self.rpe = rpe
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.averageBPM = averageBPM
        self.maxBPM = maxBPM
        self.minBPM = minBPM
        self.activeCalories = activeCalories
        self.bmrCalories = bmrCalories
        self.calories = calories
        self.epocBonusCalories = epocBonusCalories
        self.trimpScore = trimpScore
        self.cardiacDriftPercent = cardiacDriftPercent
        self.hrr60Drop = hrr60Drop
        self.autoHRREvents = autoHRREvents
        self.rmssdMs = rmssdMs
        self.strikesCuedCount = strikesCuedCount
        self.ghostBaselineName = ghostBaselineName
        self.ghostAvgDeltaBPM = ghostAvgDeltaBPM
        self.zoneSeconds = zoneSeconds
        self.roundStats = roundStats
        self.pointsOfInterest = pointsOfInterest
        self.samples = samples
        self.isCompressedArchive = isCompressedArchive
        self.archiveFileName = archiveFileName
        self.rpeRated = rpeRated
        self.planTitle = planTitle
        self.planTargetLow = planTargetLow
        self.planTargetHigh = planTargetHigh
        self.planAdherence = planAdherence
        self.trainingPlanID = trainingPlanID
        self.trainingPlanTitle = trainingPlanTitle
        self.blockResults = blockResults
        self.comboEvents = comboEvents
        self.headMovesPerMinute = headMovesPerMinute
        self.breathingGuided = breathingGuided
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        profileID = try c.decode(UUID.self, forKey: .profileID)
        profileName = try c.decode(String.self, forKey: .profileName)
        category = try c.decode(WorkoutCategory.self, forKey: .category)
        drillTag = try c.decode(DrillTag.self, forKey: .drillTag)
        rpe = try c.decode(Int.self, forKey: .rpe)
        notes = try c.decode(String.self, forKey: .notes)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        averageBPM = try c.decode(Int.self, forKey: .averageBPM)
        maxBPM = try c.decode(Int.self, forKey: .maxBPM)
        minBPM = try c.decode(Int.self, forKey: .minBPM)
        let total = try c.decode(Double.self, forKey: .calories)
        calories = total
        bmrCalories = try c.decodeIfPresent(Double.self, forKey: .bmrCalories) ?? (duration / 60.0) * 1.25
        activeCalories = try c.decodeIfPresent(Double.self, forKey: .activeCalories) ?? max(0, total - bmrCalories)
        epocBonusCalories = try c.decodeIfPresent(Double.self, forKey: .epocBonusCalories) ?? 0
        trimpScore = try c.decode(Double.self, forKey: .trimpScore)
        cardiacDriftPercent = try c.decode(Double.self, forKey: .cardiacDriftPercent)
        hrr60Drop = try c.decodeIfPresent(Int.self, forKey: .hrr60Drop)
        autoHRREvents = try c.decodeIfPresent([AutoHRREvent].self, forKey: .autoHRREvents) ?? []
        rmssdMs = try c.decodeIfPresent(Double.self, forKey: .rmssdMs)
        strikesCuedCount = try c.decodeIfPresent(Int.self, forKey: .strikesCuedCount) ?? 0
        ghostBaselineName = try c.decodeIfPresent(String.self, forKey: .ghostBaselineName)
        ghostAvgDeltaBPM = try c.decodeIfPresent(Double.self, forKey: .ghostAvgDeltaBPM)
        zoneSeconds = try c.decode([Int: TimeInterval].self, forKey: .zoneSeconds)
        roundStats = try c.decodeIfPresent([RoundStat].self, forKey: .roundStats) ?? []
        pointsOfInterest = try c.decodeIfPresent([WorkoutPOI].self, forKey: .pointsOfInterest) ?? []
        samples = try c.decodeIfPresent([HeartRatePoint].self, forKey: .samples) ?? []
        isCompressedArchive = try c.decodeIfPresent(Bool.self, forKey: .isCompressedArchive) ?? false
        archiveFileName = try c.decodeIfPresent(String.self, forKey: .archiveFileName)
        rpeRated = (try? c.decodeIfPresent(Bool.self, forKey: .rpeRated)) ?? false
        planTitle = try? c.decodeIfPresent(String.self, forKey: .planTitle)
        planTargetLow = try? c.decodeIfPresent(Int.self, forKey: .planTargetLow)
        planTargetHigh = try? c.decodeIfPresent(Int.self, forKey: .planTargetHigh)
        planAdherence = try? c.decodeIfPresent(Double.self, forKey: .planAdherence)
        trainingPlanID = try? c.decodeIfPresent(UUID.self, forKey: .trainingPlanID)
        trainingPlanTitle = try? c.decodeIfPresent(String.self, forKey: .trainingPlanTitle)
        blockResults = (try? c.decodeIfPresent([BlockResult].self, forKey: .blockResults)) ?? []
        comboEvents = (try? c.decodeIfPresent([ComboEvent].self, forKey: .comboEvents)) ?? []
        headMovesPerMinute = try? c.decodeIfPresent(Double.self, forKey: .headMovesPerMinute)
        breathingGuided = (try? c.decodeIfPresent(Bool.self, forKey: .breathingGuided)) ?? false
        roundsAutoDetected = (try? c.decodeIfPresent(Bool.self, forKey: .roundsAutoDetected)) ?? false
        focusTags = (try? c.decodeIfPresent([String].self, forKey: .focusTags)) ?? []
        partner = (try? c.decodeIfPresent(String.self, forKey: .partner)) ?? nil
        roundResults = (try? c.decodeIfPresent([String].self, forKey: .roundResults)) ?? []
        impactsCount = (try? c.decodeIfPresent(Int.self, forKey: .impactsCount)) ?? nil
        deletedAt = (try? c.decodeIfPresent(Date.self, forKey: .deletedAt)) ?? nil
        jumps = (try? c.decodeIfPresent([Double].self, forKey: .jumps)) ?? []
        run = (try? c.decodeIfPresent(RunSummary.self, forKey: .run)) ?? nil
        activityName = (try? c.decodeIfPresent(String.self, forKey: .activityName)) ?? nil
        estimatedSamples = (try? c.decodeIfPresent([HeartRatePoint].self, forKey: .estimatedSamples)) ?? []
        estimatedCalories = (try? c.decodeIfPresent(Double.self, forKey: .estimatedCalories)) ?? 0
        recoveredFromLogger = (try? c.decodeIfPresent(Int.self, forKey: .recoveredFromLogger)) ?? 0
    }

    /// Session-RPE (Foster) converted to TRIMP-equivalent units.
    var sessionRPELoad: Double {
        Double(rpe) * (duration / 60.0) * 0.25
    }

    /// Training load used everywhere in the coach: heart-rate TRIMP, blended 50/50
    /// with session-RPE once the athlete has rated the session (HR alone
    /// under-reads sparring, clinch and strength work).
    /// False when no strap was worn (no heart rate to judge zones, recovery or load by).
    /// Heart rate was really recorded: readings for a full minute, or for at least half of a short
    /// session. Low heart rate still counts; it only has to be there.
    var hasHeartRate: Bool {
        guard averageBPM > 0 else { return false }
        let covered = zoneSeconds.values.reduce(0, +)
        return covered >= 60 || (covered >= 15 && covered >= duration * 0.5)
    }

    var effectiveLoad: Double {
        guard rpeRated else { return trimpScore }
        // No heart rate: the effort rating is the whole story (averaging with 0 would halve it).
        return hasHeartRate ? (trimpScore + sessionRPELoad) / 2 : sessionRPELoad
    }

    var avgInterRoundDrop: Int? {
        let drops = roundStats.compactMap(\.stoolDropBPM)
        guard !drops.isEmpty else { return nil }
        return drops.reduce(0, +) / drops.count
    }

    var redlineSeconds: TimeInterval {
        zoneSeconds[5, default: 0]
    }

    var aerobicEfficiencyIndex: Double {
        guard averageBPM > 0 else { return 0 }
        let minutes = max(1.0, duration / 60.0)
        return (activeCalories / minutes) / (Double(averageBPM) / 100.0)
    }

    func toGhostSession() -> GhostSession {
        GhostSession(
            id: id,
            title: "\(category.rawValue) (\(startDate.formatted(date: .abbreviated, time: .omitted)))",
            subtitle: "Avg \(averageBPM) • Peak \(maxBPM) BPM",
            samples: samples,
            roundStats: roundStats,
            avgBPM: averageBPM,
            peakBPM: maxBPM
        )
    }
}

// MARK: - Physiology & Analytics Engine

enum FighterAnalytics {
    static func calculateCalorieBreakdown(bpm: Int, durationSeconds: TimeInterval, profile: AthleteProfile) -> (active: Double, bmr: Double, total: Double) {
        let minutes = durationSeconds / 60.0
        guard minutes > 0 else { return (0, 0, 0) }
        let bmr = profile.bmrCaloriesPerMinute * minutes
        guard bpm > 40 else { return (0, bmr, bmr) }

        // Keytel et al. (2005), the version that includes fitness: VO2max estimated from the
        // max/resting HR ratio (Uth et al. 2004). Much closer for fit athletes than the plain formula.
        let hr = Double(bpm), w = profile.weightKg, a = Double(profile.age)
        let vo2max = min(80, max(25, 15.3 * Double(profile.effectiveMaxHR) / Double(max(35, profile.restingHR))))
        let keytel: Double
        if profile.sex == .male {
            keytel = (-95.7735 + 0.634 * hr + 0.404 * vo2max + 0.394 * w + 0.271 * a) / 4.184
        } else {
            keytel = (-59.3954 + 0.45 * hr + 0.380 * vo2max + 0.103 * w + 0.274 * a) / 4.184
        }
        // The formula was fitted on exercise heart rates and goes wrong near rest: below ~100 BPM
        // blend into a resting-metabolism estimate scaled by heart-rate reserve.
        let reserve = max(0, min(1, (hr - Double(profile.restingHR)) / Double(max(35, profile.effectiveMaxHR - profile.restingHR))))
        let easy = profile.bmrCaloriesPerMinute * (1 + 6 * reserve)
        let u = max(0, min(1, (hr - 85) / 15))
        let totalKcalPerMin = easy * (1 - u) + max(easy, keytel) * u
        let total = max(bmr, totalKcalPerMin * minutes)
        let active = max(0, total - bmr)
        return (active, bmr, total)
    }

    static func calculateTRIMP(samples: [HeartRatePoint], profile: AthleteProfile) -> Double {
        guard samples.count >= 2 else { return 0 }
        let rest = Double(profile.restingHR)
        let span = max(35.0, Double(profile.effectiveMaxHR) - rest)
        let bFactor = profile.sex == .male ? 1.92 : 1.67
        var trimp = 0.0

        for i in 1..<samples.count {
            // A sensor dropout is not training: credit at most 5 s per gap (same as the live clock).
            let dtMinutes = min(5, max(0, samples[i].elapsedSeconds - samples[i - 1].elapsedSeconds)) / 60.0
            let hrr = min(1.0, max(0.0, (Double(samples[i].bpm) - rest) / span))
            trimp += dtMinutes * hrr * 0.64 * exp(bFactor * hrr)
        }
        return trimp
    }

    static func calculateCardiacDrift(samples: [HeartRatePoint]) -> Double {
        guard samples.count >= 20 else { return 0 }
        let trimmed = Array(samples.dropFirst(samples.count / 10))
        guard trimmed.count >= 10 else { return 0 }
        let mid = trimmed.count / 2
        let firstHalf = trimmed[..<mid].map { Double($0.bpm) }
        let secondHalf = trimmed[mid...].map { Double($0.bpm) }
        let avg1 = firstHalf.reduce(0, +) / Double(firstHalf.count)
        let avg2 = secondHalf.reduce(0, +) / Double(secondHalf.count)
        guard avg1 > 0 else { return 0 }
        return ((avg2 - avg1) / avg1) * 100.0
    }

    static func calculateRMSSD(samples: [HeartRatePoint]) -> Double? {
        let allRR = samples.flatMap(\.rrIntervalsMs).filter { $0 >= 280 && $0 <= 2000 }
        guard allRR.count >= 10 else { return nil }
        var sumSqDiff = 0.0
        for i in 1..<allRR.count {
            let diff = allRR[i] - allRR[i - 1]
            sumSqDiff += diff * diff
        }
        return sqrt(sumSqDiff / Double(allRR.count - 1))
    }

    static func calculateEPOC(zoneSeconds: [Int: TimeInterval], weightKg: Double) -> Double {
        let z4Mins = zoneSeconds[4, default: 0] / 60.0
        let z5Mins = zoneSeconds[5, default: 0] / 60.0
        let weightScale = weightKg / 75.0
        return ((z4Mins * 1.6) + (z5Mins * 3.4)) * weightScale
    }

    static func detectPointsOfInterest(
        samples: [HeartRatePoint],
        roundStats: [RoundStat],
        autoHRREvents: [AutoHRREvent],
        profile: AthleteProfile
    ) -> [WorkoutPOI] {
        guard samples.count >= 5 else { return [] }
        var pois: [WorkoutPOI] = []
        let zones = profile.activeZones

        if let peak = samples.max(by: { $0.bpm < $1.bpm }) {
            let pct = Int(round((Double(peak.bpm) / Double(profile.effectiveMaxHR)) * 100))
            pois.append(WorkoutPOI(
                elapsedSeconds: peak.elapsedSeconds,
                bpm: peak.bpm,
                shortTag: "PEAK \(peak.bpm)",
                title: "Peak Redline (\(peak.bpm) BPM)",
                detail: "Reached \(pct)% of Max HR at \(formatTime(peak.elapsedSeconds)).",
                symbol: "flame.fill",
                isPositive: false
            ))
        }

        if let bestHRR = autoHRREvents.max(by: { $0.dropBPM < $1.dropBPM }) {
            pois.append(WorkoutPOI(
                elapsedSeconds: bestHRR.elapsedSeconds,
                bpm: bestHRR.recovery60BPM,
                shortTag: "-\(bestHRR.dropBPM) HRR",
                title: "Fastest 60s Recovery (-\(bestHRR.dropBPM) BPM)",
                detail: "\(bestHRR.contextLabel): dropped \(bestHRR.peakBPM) → \(bestHRR.recovery60BPM) BPM in 60s.",
                symbol: "arrow.down.heart.fill",
                isPositive: true
            ))
        } else if let bestRound = roundStats.filter({ $0.stoolDropBPM != nil }).max(by: { ($0.stoolDropBPM ?? 0) < ($1.stoolDropBPM ?? 0) }),
                  let drop = bestRound.stoolDropBPM {
            pois.append(WorkoutPOI(
                elapsedSeconds: bestRound.endElapsed + 60,
                bpm: max(profile.restingHR, bestRound.peakBPM - drop),
                shortTag: "R\(bestRound.roundNumber) -\(drop)",
                title: "Fastest Stool Recovery (R\(bestRound.roundNumber))",
                detail: "Dropped \(drop) BPM during the 60s corner rest after Round \(bestRound.roundNumber).",
                symbol: "arrow.down.heart.fill",
                isPositive: true
            ))
        }

        for i in 0..<samples.count {
            if let future = samples[i...].first(where: { $0.elapsedSeconds - samples[i].elapsedSeconds >= 20 && $0.elapsedSeconds - samples[i].elapsedSeconds <= 26 }) {
                let rise = future.bpm - samples[i].bpm
                if rise >= 24 {
                    pois.append(WorkoutPOI(
                        elapsedSeconds: future.elapsedSeconds,
                        bpm: future.bpm,
                        shortTag: "+\(rise) SURGE",
                        title: "Explosive Output Surge (+\(rise) BPM)",
                        detail: "Jumped from \(samples[i].bpm) to \(future.bpm) BPM in 20s.",
                        symbol: "bolt.fill",
                        isPositive: false
                    ))
                    break
                }
            }
        }

        if let redline = samples.first(where: { $0.bpm > zones.z4Max }) {
            pois.append(WorkoutPOI(
                elapsedSeconds: redline.elapsedSeconds,
                bpm: redline.bpm,
                shortTag: "Z5 ENTRY",
                title: "Anaerobic Zone 5 Entry",
                detail: "Crossed \(zones.z4Max) BPM threshold at \(formatTime(redline.elapsedSeconds)).",
                symbol: "exclamationmark.triangle.fill",
                isPositive: false
            ))
        }

        return Array(pois.prefix(5))
    }

    static func formatTime(_ sec: TimeInterval) -> String {
        let s = Int(sec)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Decodes a value if it can, and nil if it can't, so one bad record in a list doesn't fail the list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
