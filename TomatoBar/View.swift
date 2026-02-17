import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

enum TBProjectAddResult {
    case added, empty, duplicate, reserved
}

enum TBProjectDeleteResult {
    case deleted, lastProject, notFound
}

final class TBProjects: ObservableObject {
    static let shared = TBProjects()

    private static let projectsKey = "projects"
    private static let selectedProjectKey = "selectedProject"
    private let userDefaults: UserDefaults

    @Published private(set) var projects: [String]
    @Published var selectedProject: String {
        didSet {
            guard projects.contains(selectedProject) else {
                selectedProject = projects.first ?? Self.defaultProjectName
                return
            }
            userDefaults.set(selectedProject, forKey: Self.selectedProjectKey)
        }
    }

    static var defaultProjectName: String {
        NSLocalizedString("TBProjects.default.name", comment: "Default project name")
    }

    static var legacyProjectName: String {
        NSLocalizedString("TBProjects.legacy.name", comment: "Legacy uncategorized project")
    }

    private var reservedProjectNames: [String] {
        [Self.legacyProjectName]
    }

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let loadedProjects = (userDefaults.stringArray(forKey: Self.projectsKey) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let normalizedProjects: [String]
        if loadedProjects.isEmpty {
            normalizedProjects = [Self.defaultProjectName]
        } else {
            normalizedProjects = loadedProjects
        }

        let loadedSelection = userDefaults.string(forKey: Self.selectedProjectKey)
        let normalizedSelection: String
        if let loadedSelection, normalizedProjects.contains(loadedSelection) {
            normalizedSelection = loadedSelection
        } else {
            normalizedSelection = normalizedProjects[0]
        }

        projects = normalizedProjects
        selectedProject = normalizedSelection

        if loadedProjects.isEmpty {
            userDefaults.set(normalizedProjects, forKey: Self.projectsKey)
        }
        if loadedSelection != normalizedSelection {
            userDefaults.set(normalizedSelection, forKey: Self.selectedProjectKey)
        }
    }

    var selectedProjectForLog: String {
        if projects.contains(selectedProject) {
            return selectedProject
        }
        return projects.first ?? Self.defaultProjectName
    }

    @discardableResult
    func addProject(named rawName: String) -> TBProjectAddResult {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .empty
        }
        if projects.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return .duplicate
        }
        if reservedProjectNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return .reserved
        }
        projects.append(name)
        userDefaults.set(projects, forKey: Self.projectsKey)
        selectedProject = name
        return .added
    }

    @discardableResult
    func deleteSelectedProject() -> TBProjectDeleteResult {
        guard projects.count > 1 else {
            return .lastProject
        }

        let projectToDelete = selectedProject
        guard let index = projects.firstIndex(of: projectToDelete) else {
            return .notFound
        }

        logger.removeEvents(forProject: projectToDelete)

        projects.remove(at: index)
        userDefaults.set(projects, forKey: Self.projectsKey)

        if !projects.contains(selectedProject) {
            selectedProject = projects.first ?? Self.defaultProjectName
        }

        return .deleted
    }
}

private struct TBTransitionLogEntry: Decodable {
    let type: String
    let timestamp: Date
    let fromState: String?
    let toState: String?
    let project: String?
}

private struct TBCompletedWorkSession {
    let start: Date
    let end: Date
    let project: String
}

private enum TBStatisticsLoader {
    static func loadCompletedWorkSessions() -> [TBCompletedWorkSession] {
        let logURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("TomatoBar.log")

        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        var transitions: [TBTransitionLogEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(TBTransitionLogEntry.self, from: lineData),
                  entry.type == "transition" else {
                continue
            }
            transitions.append(entry)
        }

        transitions.sort { $0.timestamp < $1.timestamp }

        var activeWorkStartByProject: [String: Date] = [:]
        var sessions: [TBCompletedWorkSession] = []

        for transition in transitions {
            let project = normalizedProjectName(from: transition.project)

            if transition.toState == "work" {
                activeWorkStartByProject[project] = transition.timestamp
            }

            if transition.fromState == "work" {
                guard let start = activeWorkStartByProject[project],
                      transition.timestamp > start else {
                    activeWorkStartByProject[project] = nil
                    continue
                }
                sessions.append(TBCompletedWorkSession(start: start,
                                                       end: transition.timestamp,
                                                       project: project))
                activeWorkStartByProject[project] = nil
            }
        }

        return sessions
    }

    private static func normalizedProjectName(from value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return TBProjects.legacyProjectName
        }
        return value
    }
}

extension KeyboardShortcuts.Name {
    static let startStopTimer = Self("startStopTimer")
}

private struct ProjectSelectorView: View {
    @EnvironmentObject var timer: TBTimer
    @ObservedObject private var projects = TBProjects.shared
    @State private var isNewProjectSheetPresented = false
    @State private var isDeleteProjectAlertPresented = false
    @State private var newProjectName = ""
    @State private var newProjectError: String?

    private var projectLabel = NSLocalizedString("TBPopoverView.project.label", comment: "Project label")
    private var newProjectLabel = NSLocalizedString("TBPopoverView.project.new.label",
                                                    comment: "New project action")
    private var deleteProjectLabel = NSLocalizedString("TBPopoverView.project.delete.label",
                                                       comment: "Delete project action")
    private var lockedHint = NSLocalizedString("TBPopoverView.project.locked.hint",
                                               comment: "Project is locked hint")
    private var deleteDisabledHint = NSLocalizedString("TBPopoverView.project.delete.disabled.hint",
                                                       comment: "Cannot delete the only project")
    private var createTitle = NSLocalizedString("TBPopoverView.project.new.title", comment: "Create project title")
    private var createPlaceholder = NSLocalizedString("TBPopoverView.project.new.placeholder",
                                                      comment: "Create project placeholder")
    private var createButton = NSLocalizedString("TBPopoverView.project.new.create", comment: "Create action")
    private var cancelButton = NSLocalizedString("TBPopoverView.project.new.cancel", comment: "Cancel action")
    private var errorEmpty = NSLocalizedString("TBPopoverView.project.error.empty", comment: "Project empty error")
    private var errorDuplicate = NSLocalizedString("TBPopoverView.project.error.duplicate",
                                                   comment: "Project duplicate error")
    private var errorReserved = NSLocalizedString("TBPopoverView.project.error.reserved",
                                                  comment: "Project reserved error")
    private var deleteTitle = NSLocalizedString("TBPopoverView.project.delete.title", comment: "Delete project title")
    private var deleteMessage = NSLocalizedString("TBPopoverView.project.delete.message",
                                                  comment: "Delete project confirmation message")
    private var deleteConfirmButton = NSLocalizedString("TBPopoverView.project.delete.confirm",
                                                        comment: "Delete project confirm button")
    private var deleteCancelButton = NSLocalizedString("TBPopoverView.project.delete.cancel",
                                                       comment: "Delete project cancel button")

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(projectLabel)
                    .frame(alignment: .leading)
                Picker("", selection: $projects.selectedProject) {
                    ForEach(projects.projects, id: \.self) { project in
                        Text(project).tag(project)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .disabled(timer.timer != nil)
                Button(newProjectLabel) {
                    newProjectName = ""
                    newProjectError = nil
                    isNewProjectSheetPresented = true
                }
                .disabled(timer.timer != nil)
                Button(deleteProjectLabel) {
                    isDeleteProjectAlertPresented = true
                }
                .disabled(timer.timer != nil || projects.projects.count <= 1)
            }
            if timer.timer != nil {
                Text(lockedHint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if projects.projects.count <= 1 {
                Text(deleteDisabledHint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $isNewProjectSheetPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text(createTitle)
                    .font(.headline)
                TextField(createPlaceholder, text: $newProjectName)
                if let newProjectError {
                    Text(newProjectError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                HStack {
                    Spacer()
                    Button(cancelButton) {
                        isNewProjectSheetPresented = false
                    }
                    Button(createButton) {
                        createProject()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 320)
        }
        .alert(isPresented: $isDeleteProjectAlertPresented) {
            Alert(title: Text(deleteTitle),
                  message: Text(String(format: deleteMessage, projects.selectedProject)),
                  primaryButton: .destructive(Text(deleteConfirmButton)) {
                      deleteSelectedProject()
                  },
                  secondaryButton: .cancel(Text(deleteCancelButton)))
        }
    }

    private func createProject() {
        switch projects.addProject(named: newProjectName) {
        case .added:
            isNewProjectSheetPresented = false
        case .empty:
            newProjectError = errorEmpty
        case .duplicate:
            newProjectError = errorDuplicate
        case .reserved:
            newProjectError = errorReserved
        }
    }

    private func deleteSelectedProject() {
        _ = projects.deleteSelectedProject()
    }
}

private struct IntervalsView: View {
    @EnvironmentObject var timer: TBTimer
    private var minStr = NSLocalizedString("IntervalsView.min", comment: "min")

    var body: some View {
        VStack {
            Stepper(value: $timer.workIntervalLength, in: 1 ... 60) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.workIntervalLength.label",
                                           comment: "Work interval label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String.localizedStringWithFormat(minStr, timer.workIntervalLength))
                }
            }
            Stepper(value: $timer.shortRestIntervalLength, in: 1 ... 60) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.shortRestIntervalLength.label",
                                           comment: "Short rest interval label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String.localizedStringWithFormat(minStr, timer.shortRestIntervalLength))
                }
            }
            Stepper(value: $timer.longRestIntervalLength, in: 1 ... 60) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.longRestIntervalLength.label",
                                           comment: "Long rest interval label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String.localizedStringWithFormat(minStr, timer.longRestIntervalLength))
                }
            }
            .help(NSLocalizedString("IntervalsView.longRestIntervalLength.help",
                                    comment: "Long rest interval hint"))
            Stepper(value: $timer.workIntervalsInSet, in: 1 ... 10) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.workIntervalsInSet.label",
                                           comment: "Work intervals in a set label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(timer.workIntervalsInSet)")
                }
            }
            .help(NSLocalizedString("IntervalsView.workIntervalsInSet.help",
                                    comment: "Work intervals in set hint"))
            Spacer().frame(minHeight: 0)
        }
        .padding(4)
    }
}

private struct SettingsView: View {
    @EnvironmentObject var timer: TBTimer
    @ObservedObject private var launchAtLogin = LaunchAtLogin.observable

    var body: some View {
        VStack {
            KeyboardShortcuts.Recorder(for: .startStopTimer) {
                Text(NSLocalizedString("SettingsView.shortcut.label",
                                       comment: "Shortcut label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(isOn: $timer.stopAfterBreak) {
                Text(NSLocalizedString("SettingsView.stopAfterBreak.label",
                                       comment: "Stop after break label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
            Toggle(isOn: $timer.showTimerInMenuBar) {
                Text(NSLocalizedString("SettingsView.showTimerInMenuBar.label",
                                       comment: "Show timer in menu bar label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
                .onChange(of: timer.showTimerInMenuBar) { _ in
                    timer.updateTimeLeft()
                }
            Toggle(isOn: $launchAtLogin.isEnabled) {
                Text(NSLocalizedString("SettingsView.launchAtLogin.label",
                                       comment: "Launch at login label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
            Spacer().frame(minHeight: 0)
        }
        .padding(4)
    }
}

private struct VolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        Slider(value: $volume, in: 0...2) {
            Text(String(format: "%.1f", volume))
        }.gesture(TapGesture(count: 2).onEnded({
            volume = 1.0
        }))
    }
}

private struct SoundsView: View {
    @EnvironmentObject var player: TBPlayer

    private var columns = [
        GridItem(.flexible()),
        GridItem(.fixed(110))
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("SoundsView.isWindupEnabled.label",
                                   comment: "Windup label"))
            VolumeSlider(volume: $player.windupVolume)
            Text(NSLocalizedString("SoundsView.isDingEnabled.label",
                                   comment: "Ding label"))
            VolumeSlider(volume: $player.dingVolume)
            Text(NSLocalizedString("SoundsView.isTickingEnabled.label",
                                   comment: "Ticking label"))
            VolumeSlider(volume: $player.tickingVolume)
        }.padding(4)
        Spacer().frame(minHeight: 0)
    }
}

private struct StatisticsProjectFilterOption: Hashable {
    let id: String
    let title: String
    let project: String?
}

private struct StatisticsView: View {
    @ObservedObject private var projects = TBProjects.shared

    @State private var selectedProjectFilterID = "__all_projects__"
    @State private var rangeStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var rangeEndDate = Date()
    @State private var sessions: [TBCompletedWorkSession] = []

    private let allProjectsFilterID = "__all_projects__"

    private var allProjectsLabel = NSLocalizedString("TBStatistics.allProjects.label", comment: "All projects")
    private var projectLabel = NSLocalizedString("StatisticsView.project.label", comment: "Project label")
    private var fromLabel = NSLocalizedString("StatisticsView.from.label", comment: "From label")
    private var toLabel = NSLocalizedString("StatisticsView.to.label", comment: "To label")
    private var totalLabel = NSLocalizedString("StatisticsView.total.label", comment: "Total work duration label")
    private var completedLabel = NSLocalizedString("StatisticsView.completed.label", comment: "Completed pomodoros label")
    private var refreshLabel = NSLocalizedString("StatisticsView.refresh.label", comment: "Refresh label")

    private var filterOptions: [StatisticsProjectFilterOption] {
        var options: [StatisticsProjectFilterOption] = [
            StatisticsProjectFilterOption(id: allProjectsFilterID, title: allProjectsLabel, project: nil)
        ]

        for project in projects.projects {
            options.append(StatisticsProjectFilterOption(id: "project::\(project)",
                                                         title: project,
                                                         project: project))
        }

        let legacyName = TBProjects.legacyProjectName
        if !options.contains(where: { $0.project == legacyName }) {
            options.append(StatisticsProjectFilterOption(id: "project::\(legacyName)",
                                                         title: legacyName,
                                                         project: legacyName))
        }

        let historicalProjects = Array(Set(sessions.map(\.project))).sorted()
        for project in historicalProjects where !options.contains(where: { $0.project == project }) {
            options.append(StatisticsProjectFilterOption(id: "project::\(project)",
                                                         title: project,
                                                         project: project))
        }

        return options
    }

    private var selectedProjectName: String? {
        filterOptions.first(where: { $0.id == selectedProjectFilterID })?.project
    }

    private var normalizedRange: DateInterval {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: min(rangeStartDate, rangeEndDate))
        let endDay = calendar.startOfDay(for: max(rangeStartDate, rangeEndDate))
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        return DateInterval(start: startDay, end: endExclusive)
    }

    private var totalWorkSeconds: TimeInterval {
        filteredSessions.reduce(0) { total, session in
            let overlapStart = max(session.start, normalizedRange.start)
            let overlapEnd = min(session.end, normalizedRange.end)
            return total + max(0, overlapEnd.timeIntervalSince(overlapStart))
        }
    }

    private var completedSessionCount: Int {
        filteredSessions.filter { session in
            let overlapStart = max(session.start, normalizedRange.start)
            let overlapEnd = min(session.end, normalizedRange.end)
            return overlapEnd > overlapStart
        }.count
    }

    private var filteredSessions: [TBCompletedWorkSession] {
        if let selectedProjectName {
            return sessions.filter { $0.project == selectedProjectName }
        }
        return sessions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(projectLabel)
                    .frame(width: 56, alignment: .leading)
                Picker("", selection: $selectedProjectFilterID) {
                    ForEach(filterOptions, id: \.self) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                Text(fromLabel)
                DatePicker("", selection: $rangeStartDate, displayedComponents: [.date])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Text(toLabel)
                DatePicker("", selection: $rangeEndDate, displayedComponents: [.date])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            Divider()

            HStack {
                Text(totalLabel)
                Spacer()
                Text(durationString(from: totalWorkSeconds))
                    .font(.system(.body).monospacedDigit())
            }

            HStack {
                Text(completedLabel)
                Spacer()
                Text("\(completedSessionCount)")
            }

            HStack {
                Spacer()
                Button(refreshLabel) {
                    reloadSessions()
                }
            }

            Spacer().frame(minHeight: 0)
        }
        .padding(4)
        .onAppear {
            normalizeSelection()
            reloadSessions()
        }
        .onChange(of: projects.projects) { _ in
            normalizeSelection()
            reloadSessions()
        }
    }

    private func normalizeSelection() {
        if !filterOptions.contains(where: { $0.id == selectedProjectFilterID }) {
            selectedProjectFilterID = allProjectsFilterID
        }
    }

    private func reloadSessions() {
        sessions = TBStatisticsLoader.loadCompletedWorkSessions()
    }

    private func durationString(from seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: seconds) ?? "0m"
    }
}

private enum ChildView {
    case intervals, settings, sounds, statistics
}

struct TBPopoverView: View {
    @ObservedObject var timer = TBTimer()
    @State private var buttonHovered = false
    @State private var activeChildView = ChildView.intervals

    private var startLabel = NSLocalizedString("TBPopoverView.start.label", comment: "Start label")
    private var stopLabel = NSLocalizedString("TBPopoverView.stop.label", comment: "Stop label")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProjectSelectorView().environmentObject(timer)

            Button {
                timer.startStop()
                TBStatusItem.shared.closePopover(nil)
            } label: {
                Text(timer.timer != nil ?
                     (buttonHovered ? stopLabel : timer.timeLeftString) :
                        startLabel)
                    /*
                      When appearance is set to "Dark" and accent color is set to "Graphite"
                      "defaultAction" button label's color is set to the same color as the
                      button, making the button look blank. #24
                     */
                    .foregroundColor(Color.white)
                    .font(.system(.body).monospacedDigit())
                    .frame(maxWidth: .infinity)
            }
            .onHover { over in
                buttonHovered = over
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Picker("", selection: $activeChildView) {
                Text(NSLocalizedString("TBPopoverView.intervals.label",
                                       comment: "Intervals label")).tag(ChildView.intervals)
                Text(NSLocalizedString("TBPopoverView.settings.label",
                                       comment: "Settings label")).tag(ChildView.settings)
                Text(NSLocalizedString("TBPopoverView.sounds.label",
                                       comment: "Sounds label")).tag(ChildView.sounds)
                Text(NSLocalizedString("TBPopoverView.statistics.label",
                                       comment: "Statistics label")).tag(ChildView.statistics)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .pickerStyle(.segmented)

            GroupBox {
                switch activeChildView {
                case .intervals:
                    IntervalsView().environmentObject(timer)
                case .settings:
                    SettingsView().environmentObject(timer)
                case .sounds:
                    SoundsView().environmentObject(timer.player)
                case .statistics:
                    StatisticsView()
                }
            }

            Group {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel()
                } label: {
                    Text(NSLocalizedString("TBPopoverView.about.label",
                                           comment: "About label"))
                    Spacer()
                    Text("⌘ A").foregroundColor(Color.gray)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("a")
                Button {
                    NSApplication.shared.terminate(self)
                } label: {
                    Text(NSLocalizedString("TBPopoverView.quit.label",
                                           comment: "Quit label"))
                    Spacer()
                    Text("⌘ Q").foregroundColor(Color.gray)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
        }
        #if DEBUG
            /*
             After several hours of Googling and trying various StackOverflow
             recipes I still haven't figured a reliable way to auto resize
             popover to fit all it's contents (pull requests are welcome!).
             The following code block is used to determine the optimal
             geometry of the popover.
             */
            .overlay(
                GeometryReader { proxy in
                    debugSize(proxy: proxy)
                }
            )
        #endif
            /* Use values from GeometryReader */
//            .frame(width: 240, height: 276)
            .padding(12)
    }
}

#if DEBUG
    func debugSize(proxy: GeometryProxy) -> some View {
        print("Optimal popover size:", proxy.size)
        return Color.clear
    }
#endif
