import SwiftUI

/// The app's frame: Corner and Record, with the red Start button between them.
/// Both screens stay alive, so switching never loses your place.
struct RootView: View {
    @EnvironmentObject var navigation: AppNavigation
    @Environment(WorkoutSession.self) var session

    var body: some View {
        ZStack {
            LiveWorkoutView()
                .opacity(navigation.selectedTab == .corner ? 1 : 0)
                .allowsHitTesting(navigation.selectedTab == .corner)
                .accessibilityHidden(navigation.selectedTab != .corner)
            RecordView()
                .opacity(navigation.selectedTab == .record ? 1 : 0)
                .allowsHitTesting(navigation.selectedTab == .record)
                .accessibilityHidden(navigation.selectedTab != .record)
        }
        // Every list and scroll view (including pushed screens) gets room under its
        // content, so nothing ends up hidden behind the tab bar.
        .contentMargins(.bottom, session.isRecording ? 0 : FightTabBar.height + 16, for: .scrollContent)
        .contentMargins(.bottom, session.isRecording ? 0 : FightTabBar.height, for: .scrollIndicators)
        .overlay(alignment: .bottom) {
            // While training, the live screen owns the bottom of the screen.
            if !session.isRecording {
                FightTabBar()
            }
        }
        .onChange(of: session.isRecording) { _, recording in
            if recording { navigation.selectedTab = .corner }
        }
        .sheet(isPresented: $navigation.showingYou) {
            ProfileSettingsView()
        }
    }
}

/// Corner · START · Record.
struct FightTabBar: View {
    @EnvironmentObject var navigation: AppNavigation
    /// Height above the home indicator, for content margins.
    static let height: CGFloat = 62

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            tab(.corner, title: "Corner", icon: "figure.boxing")
            Button {
                navigation.selectedTab = .corner
                navigation.showingStart = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.red)
                        .frame(width: 64, height: 64)
                    Image(systemName: "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(y: -12)
            .frame(width: 96)
            .accessibilityLabel("Start training")
            .sensoryFeedback(.impact(weight: .medium), trigger: navigation.showingStart)
            tab(.record, title: "Record", icon: "chart.bar.fill")
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func tab(_ t: AppNavigation.Tab, title: String, icon: String) -> some View {
        let selected = navigation.selectedTab == t
        return Button {
            navigation.selectedTab = t
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(selected ? Theme.red : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Sessions and Trends under one roof.
struct RecordView: View {
    @EnvironmentObject var navigation: AppNavigation

    var body: some View {
        ZStack {
            HistoryListView()
                .opacity(navigation.recordSegment == .sessions ? 1 : 0)
                .allowsHitTesting(navigation.recordSegment == .sessions)
                .accessibilityHidden(navigation.recordSegment != .sessions)
            CoachView()
                .opacity(navigation.recordSegment == .trends ? 1 : 0)
                .allowsHitTesting(navigation.recordSegment == .trends)
                .accessibilityHidden(navigation.recordSegment != .trends)
        }
    }
}

/// The Sessions | Trends switch at the top of Record.
struct RecordSwitcher: View {
    @EnvironmentObject var navigation: AppNavigation

    var body: some View {
        Picker("Show", selection: $navigation.recordSegment) {
            Text("Sessions").tag(AppNavigation.RecordSegment.sessions)
            Text("Trends").tag(AppNavigation.RecordSegment.trends)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Your initials in the top corner: opens You (profile and settings).
struct AvatarButton: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation

    private var initials: String {
        let parts = workoutStore.activeProfile.name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map { String($0) }.joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    var body: some View {
        Button {
            navigation.showingYou = true
        } label: {
            Text(initials)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.red, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("You and settings")
    }
}
