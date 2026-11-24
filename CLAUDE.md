# FIGHT

Heart-rate training app for iPhone, built for kickboxing, Muay Thai, MMA, boxing and grappling.
SwiftUI, iOS 17, Swift 5 language mode. Works with any standard Bluetooth heart-rate strap, plus
the optional FIGHT Logger (a small box on the band, see `Firmware/`).

## How the owner works (read first)

- **No Mac.** The owner develops on Windows (repo at `X:\projects\CoospoTracker`). iOS builds and
  tests only run in GitHub Actions on macOS. The unsigned IPA is sideloaded with Sideloadly.
- **Commits:** author `drivepulator <296496310+drivepulator@users.noreply.github.com>`.
  **No Claude attribution, co-author lines or tags in commits or PRs.**
- **Branches:** work on a feature branch, never straight on `main`. Push only when the owner says so.
- **Before saying something works, the cloud build must be green:**
  1. Push the branch.
  2. Trigger CI: `gh api -X POST repos/drivepulator/fight/actions/workflows/build.yml/dispatches -f ref=<branch>`
  3. Poll: `gh run view <id> -R drivepulator/fight --json status,conclusion`
  4. Fix any compile or test failure, then push again.
- **Merging:** only when the owner says "merge it". Fast-forward `main`, push, confirm the `main`
  build is green, then remind the owner to `git pull`.
- **Can't test on a device here.** Say plainly what was only compiled and unit-tested, and what
  needs a real phone, strap or logger to confirm.

## Product rules

- **Simple and dumb-proof.** No extra options, no half-separated features. If a setting isn't
  clearly needed, leave it out.
- **Fighter language**, human tone: "roadwork", "rounds", "corner", "gloves on". Sentence case.
- **Glove-friendly live screen:** big targets (bottom quarter of the screen), hold-to-end with a
  3-2-1 countdown, never something that stops a session by accident.
- **Real vs estimated data stay separate.** Estimated heart rate (strap dropped out) is shown with
  ≈, grey and dashed, and never counts toward averages, zones, calories or records.
- **Voice coaching only speaks when it matters:** out-of-range alerts ("Slow down. Above target." /
  "Pick it up. Under target."), bells, round warnings, bag combos. No periodic heart-rate chatter.
  Coach style: "Like a coach" or "Alerts only".

## Layout

- `project.yml`: XcodeGen spec. The **test target lists specific app files**: a new file used by
  tests must be added there too.
- `Sources/App/`:
  - Navigation: `FightApp`, `NavigationShell` (Corner / red Start button / Record tabs, You sheet),
    `AppNavigation`.
  - Home and start: `CornerViews`, `TodayViews`, `WorkoutPickerViews` (Start sheet, doors,
    ready screen), `WorkoutMenu`.
  - Live session: `WorkoutSession` (the engine: timing, rounds, pause, get-ready, calories,
    alerts, estimates, logger merge, saving), `LiveWorkoutView` (swipe pages + bottom controls),
    `HoldCountdown`.
  - Sensors and audio: `BLEHeartRateManager` (straps and the logger), `RunTracker`, `RouteMath`
    (GPS roadwork), `AudioCoachEngine` (voice, bells, bag coach, music ducking), `HeadMotionTracker`.
  - Heart-rate logic: `HRAlerts` (targets + when to speak), `HREstimator` (gap estimates),
    `LoggerProtocol` (FIGHT Logger messages).
  - Data and analysis: `Models` (profile, zones, saved workouts, calorie formulas), `WorkoutStore`
    (storage), `CoachEngine`, `Insights`, `WeeklyReport`, `CampPlanner`.
  - Look: `Theme` (one red accent #E8262E, dark-first, shared components), `SimpleUI`.
  - `WorkoutDetailView`: session summary, scorecard, Discard / Resume.
- `Sources/PlanKit/`: training plans and sharing them by link or QR.
- `Sources/Widget/`, `Sources/Shared/`: Live Activity (lock screen, Dynamic Island).
- `Tests/FIGHTTests/`: unit tests (135+). Add tests for any new calculation.
- `Firmware/FightLogger/`: FIGHT Logger firmware for a Seeed XIAO nRF52840 (Arduino, Bluefruit).
  Built by `.github/workflows/logger.yml` into `FIGHT-Logger-UF2` (drag-and-drop file).
  The message format must match `LoggerProtocol.swift`.
- `docs/assets/`: README banner and logo.

## Compile pitfalls (CI is the only compiler)

- SwiftUI view builders: at most 10 direct children; wrap extras in `Group`.
- No tuple key paths, no `if let (a, b) =`, `@discardableResult` goes directly on the func.
- `@ObservationIgnored` only on `var`, never `let` or `lazy`.
- Never swap a view's whole content under a finger mid-gesture (it cancels the touch). Fade
  between pieces that are always present instead, as `HoldToEndButton` does.
- Saved data is Codable with `decodeIfPresent` for every new field, so old files keep loading.

## Calculations (keep these)

- Calories on GPS roadwork: ACSM walking and running equations from distance and climb.
- Calories otherwise: Keytel heart-rate formula, applied in full from 50% of heart-rate reserve,
  blended from a resting-based estimate at 25%.
- Zones: Karvonen, % max HR, threshold (running percentages 85/89/94/99% of LTHR) or manual.
- Load: Banister TRIMP; fitness and fatigue as 42- and 7-day averages.

## Open items

- `hr-alerts` branch (all green, not merged yet): out-of-range voice alerts and coach style,
  estimated heart rate, music volume fix, FIGHT Logger support, calorie and zone fixes.
- FIGHT Logger hardware not built yet: firmware and app support are untested on a real board.
- Discard then Undo doesn't re-send the session to Apple Health.
- App Store / TestFlight: needs the $99/year developer membership, then CI signing.
