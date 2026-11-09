import SwiftUI
import Charts

struct ActivityTimersView: View {
    @ObservedObject var store: PlanStore
    @State private var newName = ""
    @State private var selection = ActivitySelectionState()
    @State private var mode: ActivityTimerMode = .stopwatch
    @State private var hours = "0"
    @State private var minutes = "25"
    @State private var seconds = "0"
    @State private var range = 0
    @State private var sortOrder: ActivityDurationSortOrder = .descending
    @State private var addingRecord = false
    @State private var visibleSessions = 20
    @State private var inputError: String?
    @State private var inputContext: ActivityInputContext = .setup
    @State private var section = 0
    @State private var projectQuery = ""
    @State private var statisticsQuery = ""
    @State private var creatingProject = false
    @State private var selectedDay: Date?
    @State private var recordDay: Date?
    @State private var recordProject: UUID?
    @State private var recordQuery = ""
    @State private var restoredPreferences = false
    @State private var expandedLegend = false
    @State private var previousSessionID: UUID?
    @State private var finishedRecordID: UUID?
    var initialSection: Int? = nil

    private var availableProjects: [TimedActivity] {
        store.activityTimers.activities.filter { !$0.isArchived && matches($0.name, query: projectQuery) }
    }

    private func matches(_ text: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || text.localizedStandardContains(query)
    }

    private var pageError: String? {
        if inputContext == .page, let inputError { return inputError }
        return store.activityTimerError == inputError ? nil : store.activityTimerError
    }

    private var recentSessions: [ActivityTimerSession] {
        store.activityStatistics().completedSessions
    }

    private func color(for id: UUID) -> Color {
        ActivityChartPalette.color(store.activityTimers.activities.first { $0.id == id }?.colorIndex ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DeskPageIcon(symbol: "timer", theme: store.theme)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("事项计时")).font(.system(size: 22, weight: .bold)).fontDesign(store.theme.design)
                    Text(L("给每一次投入留下一份记录")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                ZStack {
                    if store.activitySaveInProgress { ProgressView().controlSize(.small).accessibilityLabel(L("正在保存记录…")) }
                }.frame(width: 14, height: 14)
                Button(L("今日计划")) { store.onShowPlan?() }
                    .controlSize(.regular)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if !store.activityDataReady {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("正在载入计时记录…")) }
                    .font(.callout).foregroundStyle(.secondary).padding(14)
            }
            if let pageError {
                ActivityInlineError(message: pageError)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
            if store.activityDataReady {
                if section != 0, store.activityTimers.displayedSession != nil {
                    ActivityTimerStrip(store: store, onOpen: { section = 0 }).padding(.horizontal, 20).padding(.top, 10)
                }
                Picker(L("查看区域"), selection: $section) {
                    Text(L("计时")).tag(0)
                    Text(L("学习统计")).tag(1)
                    Text(L("学习记录")).tag(2)
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.vertical, 10)
                    .accessibilityIdentifier("activityWorkspaceSection")
                HStack {
                    if let title = store.activityUndoTitle {
                        Button(title) { Task { report(await store.undoActivityChange(), at: .page) } }
                            .disabled(store.activityIsBusy).accessibilityIdentifier("undoActivityChange")
                    }
                    if let title = store.activityRedoTitle {
                        Button(title) { Task { report(await store.redoActivityChange(), at: .page) } }
                            .disabled(store.activityIsBusy)
                    }
                    Spacer()
                    if store.activitySaveInProgress { Text(L("正在保存记录…")).font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 20)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if section == 0, let session = store.activityTimers.displayedSession {
                        ClockDrivenContent(clock: store.clock, enabled: session.runningSince != nil) { activeTimer(session) }
                    }
                    if store.activityDataReady {
                        if section == 0 {
                            if let id = finishedRecordID, let finished = store.activityTimers.sessions.first(where: { $0.id == id && $0.endedAt != nil }) {
                                HStack {
                                    Text(L("已记录：%@ · %@", name(for: finished.activityID), ActivityDurationFormat.summary(finished.savedDuration)))
                                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Button(L("补充本次内容")) { selection.editingSession = finished }
                                        .disabled(store.activityIsBusy).accessibilityIdentifier("noteFinishedActivity")
                                    Button(L("关闭")) { finishedRecordID = nil }
                                }.modifier(DeskSurface(theme: store.theme))
                            }
                            recentProjects; setup
                        }
                        if section == 1 {
                            ClockDrivenContent(clock: store.clock, enabled: store.activityTimers.activeSession?.runningSince != nil) { statistics }
                        }
                        if section == 2 { records }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 680, minHeight: 540)
        .modifier(ThemeSurface(store: store))
        .id(store.language)
        .onAppear(perform: restorePreferences)
        .onChange(of: store.activityDataReady) { _ in restorePreferences() }
        .onChange(of: store.activityRevision) { _ in synchronizeSelection() }
        .onChange(of: store.activityTimers.displayedSession?.id) { id in
            if let previous = previousSessionID, previous != id,
               store.activityTimers.sessions.contains(where: { $0.id == previous && $0.endedAt != nil }) { finishedRecordID = previous }
            previousSessionID = id
        }
        .onChange(of: section) { store.rememberActivitySection(ActivityWorkspaceSection(rawValue: $0) ?? .timer) }
        .onChange(of: store.activityExperience.section) { if initialSection == nil { section = $0.rawValue } }
        .onChange(of: selection.selectedForTotal) { if restoredPreferences { store.rememberActivitySelection($0) } }
        .onChange(of: selection.activityID) { id in
            guard let id else { return }
            let preference = store.timerPreference(for: id)
            mode = preference.mode
            let duration = Int(preference.duration ?? 1500)
            hours = "\(duration / 3600)"; minutes = "\(duration % 3600 / 60)"; seconds = "\(duration % 60)"
        }
        .onChange(of: range) { value in
            store.rememberActivityRange(value)
            if let selectedDay, value > 0,
               selectedDay < Calendar.current.date(byAdding: .day, value: 1 - value, to: Calendar.current.startOfDay(for: store.now))! { self.selectedDay = nil }
        }
        .onChange(of: sortOrder) { _ in
            store.rememberActivitySort(sortOrder)
            if selection.editingActivityID != nil { selection.editingOrder = store.activityStatistics().summaries(days: range, order: sortOrder).map(\.id) }
        }
        .sheet(item: $selection.editingSession) { session in
            ActivityRecordEditor(store: store, session: session)
        }
        .sheet(isPresented: $addingRecord) {
            ActivityRecordEditor(store: store)
        }
        .alert(L("删除计时项目？"), isPresented: Binding(
            get: { selection.pendingDeletion != nil },
            set: { if !$0 { selection.pendingDeletion = nil } }
        ), presenting: selection.pendingDeletion) { activity in
            Button(L("取消"), role: .cancel) { selection.pendingDeletion = nil }
            Button(L("删除项目及记录"), role: .destructive) { deleteActivity(activity) }
        } message: { activity in
            Text(L("将删除“%@”及其全部计时记录和累计时长，无法撤销。", "\(activity.name)")
                 + (store.activityTimers.activeSession?.activityID == activity.id ? L("当前计时也将停止。") : "")
                 + L("如果只是打错字，可取消后点击铅笔修改名称，保留已有记录。"))
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeskSectionHeading(title: L("开始一次计时"), symbol: "play.circle", theme: store.theme)
            DisclosureGroup(L("新建项目"), isExpanded: $creatingProject) {
            HStack {
                TextField(L("新项目名称，例如：阅读、运动"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addActivity)
                    .accessibilityIdentifier("newActivityName")
                Button(L("添加项目"), action: addActivity)
                    .disabled(store.activityIsBusy || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("addTimedActivity")
            }
            if let archived = store.activityTimers.activities.first(where: { $0.isArchived && $0.name.compare(newName.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                Button(L("恢复已有归档项目：%@", archived.name)) { perform(.archive(archived.id, false), at: .setup) }
                    .disabled(store.activityIsBusy)
            }
            }
            if store.activityTimers.activities.filter({ !$0.isArchived }).isEmpty {
                Text(L("先添加一个项目，之后每次选择它计时，时长会自动累计。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TextField(L("查找项目（不改变统计筛选）"), text: $projectQuery)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("activityProjectSearch")
                    .onSubmit { if availableProjects.count == 1 { selection.activityID = availableProjects[0].id } }
                if availableProjects.isEmpty { Text(L("没有匹配的项目。")).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Text(L("计时项目"))
                    Menu {
                        Picker(L("计时项目"), selection: $selection.activityID) {
                            Text(L("请选择项目")).tag(nil as UUID?)
                            ForEach(availableProjects) { activity in
                                Text(activity.name).tag(Optional(activity.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Text(selection.activityID.map { name(for: $0) } ?? L("请选择项目"))
                            .foregroundStyle(store.theme.foreground).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
                    .accessibilityIdentifier("activityProjectPicker")
                    .help(selection.activityID.map { name(for: $0) } ?? L("请选择项目"))
                }
                Picker(L("计时方式"), selection: $mode) {
                    ForEach(ActivityTimerMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("activityTimerMode")
                if mode == .countdown {
                    HStack(spacing: 8) {
                        Text(L("时长"))
                        durationField(L("小时"), text: $hours)
                        durationField(L("分"), text: $minutes)
                        durationField(L("秒"), text: $seconds)
                        Spacer()
                    }
                }
                HStack {
                    Text(mode == .countdown ? L("到时自动结束并记录，支持 1 秒至 7 天。") : L("从零开始记录，结束时保存本次实际时长。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(store.activityTimers.activeSession == nil ? L("开始计时") : L("切换到所选项目"), action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(store.activityIsBusy || selection.activityID == nil || selection.activityID == store.activityTimers.activeSession?.activityID)
                        .accessibilityIdentifier("startActivityTimer")
                }
            }
            inlineError(for: .setup)
            Text(L("每次仅计时一个项目；睡眠自动暂停，唤醒后手动继续，暂停时间不计入。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L("已归档项目")) {
                ForEach(store.activityTimers.activities.filter { $0.isArchived && matches($0.name, query: projectQuery) }) { activity in
                    HStack {
                        ActivityChartBadge(activity: activity)
                        Text(activity.name)
                        Spacer()
                        Button(L("恢复项目")) { perform(.archive(activity.id, false), at: .setup) }.disabled(store.activityIsBusy)
                    }.padding(.vertical, 4)
                }
                Text(L("归档只隐藏开始入口，历史统计和记录仍保留。")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .modifier(DeskSurface(theme: store.theme))
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeskSectionHeading(title: L("最近项目"), symbol: "clock", theme: store.theme)
            ForEach(store.recentActivities) { activity in
                let preference = store.timerPreference(for: activity.id)
                HStack {
                    ActivityChartBadge(activity: activity)
                    Text(activity.name).lineLimit(2)
                    Spacer()
                    Text(preference.mode == .stopwatch ? L("正计时") : ActivityDurationFormat.summary(preference.duration ?? 1500))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("开始")) { perform(.start(activity.id, preference.mode, preference.duration), at: .setup) }
                        .disabled(store.activityIsBusy || store.activityTimers.activeSession != nil)
                        .accessibilityIdentifier("recentActivityStart-\(activity.id)")
                }
            }
            if store.recentActivities.isEmpty { Text(L("完成一次计时后，最近项目会出现在这里。")).foregroundStyle(.secondary).font(.callout) }
        }.modifier(DeskSurface(theme: store.theme))
    }

    private func durationField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField(label, text: text).textFieldStyle(.roundedBorder).frame(width: 50)
                .accessibilityLabel(L("倒计时%@", "\(label)"))
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func activeTimer(_ session: ActivityTimerSession) -> some View {
        let isDue = session.isAwaitingCompletion
        let accent = isDue ? store.theme.finished : store.theme.accent
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(isDue ? L("已到时 · 可继续专注") : session.isPaused ? L("已暂停") : L("正在%@", "\(session.mode.title)"),
                      systemImage: isDue ? "checkmark.circle" : session.isPaused ? "pause.circle" : "timer")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(accent.opacity(0.09), in: Capsule())
                Spacer()
                Text(session.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Text(name(for: session.activityID)).font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(isDue ? L("已到时") : ActivityDurationFormat.clock(session.mode == .countdown ? session.remaining(at: store.activityDisplayNow) : session.elapsed(at: store.activityDisplayNow), roundUp: session.mode == .countdown))
                    .font(.system(size: isDue ? 32 : 42, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(isDue ? accent : .primary)
                    .accessibilityIdentifier("activityTimerClock")
                if !isDue {
                    Text(session.mode == .countdown ? L("剩余") : L("已用时")).foregroundStyle(.secondary)
                }
                Spacer()
                if isDue {
                    Button(L("+5 分钟")) { perform(.extend, at: .timer) }
                        .disabled(store.activityIsBusy)
                        .help(L("从现在开始，为这个项目再计时 5 分钟"))
                } else {
                    Button(session.isPaused ? L("继续") : L("暂停")) { perform(.togglePause, at: .timer) }
                        .disabled(store.activityIsBusy)
                }
                Button(isDue ? L("完成") : L("结束并记录")) { perform(.finish, at: .page) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(store.activityIsBusy)
            }
            if session.targetDuration != nil {
                ProgressView(value: session.progress(at: store.activityDisplayNow)).tint(accent)
            }
            inlineError(for: .timer)
            if isDue {
                Text(L("这段专注已计入累计时长。准备好后，可以完成或再专注 5 分钟。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .modifier(DeskSurface(theme: store.theme, emphasized: true))
    }

    private var statistics: some View {
        let snapshot = store.activityStatistics()
        let summaries = snapshot.summaries(days: range, order: sortOrder)
        let largestDuration = max(1, summaries.map(\.duration).max() ?? 0)
        let total = summaries.filter { selection.selectedForTotal.contains($0.id) }.reduce(0) { $0 + $1.duration }
        let frozenOrder = Dictionary(uniqueKeysWithValues: selection.editingOrder.enumerated().map { ($0.element, $0.offset) })
        let displayed = selection.editingActivityID == nil ? summaries : summaries.sorted {
            (frozenOrder[$0.id] ?? Int.max) < (frozenOrder[$1.id] ?? Int.max)
        }
        return Group {
            summaryCard(total: total)
            HStack {
                TextField(L("查找项目（不改变统计筛选）"), text: $statisticsQuery).textFieldStyle(.roundedBorder)
                Button(L("返回全部")) { selection.selectedForTotal = Set(store.activityTimers.activities.map(\.id)); statisticsQuery = "" }
            }
            Text(L("当前筛选：%@ 项；查询只缩小下方项目列表。", "\(selection.selectedForTotal.count)"))
                .font(.caption).foregroundStyle(.secondary)
            if !statisticsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let found = store.activityTimers.activities.filter { matches($0.name, query: statisticsQuery) }
                // Lazy stacks flatten these candidates beside distribution
                // rows. Keep their identities distinct from UUID row IDs.
                ForEach(found.prefix(5), id: \.chartLabel) { activity in
                    HStack {
                        ActivityChartBadge(activity: activity)
                        Text(activity.name).lineLimit(2)
                        if activity.isArchived { Text(L("已归档")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(L("只看此项目")) { selection.selectedForTotal = [activity.id] }
                            .accessibilityIdentifier("focusActivity-\(activity.id)")
                    }.padding(.vertical, 3)
                }
                if found.isEmpty { Text(L("没有匹配的项目。")).font(.callout).foregroundStyle(.secondary) }
            }
            if range != 1 { dailyChart(snapshot: snapshot) }
            if let day = selectedDay ?? (range == 1 ? Calendar.current.startOfDay(for: store.now) : nil) {
                dayDetails(day, snapshot: snapshot)
            }
            DeskSectionHeading(title: L("项目时长分布"), symbol: "chart.bar", theme: store.theme)
            if summaries.isEmpty {
                Text(L("添加学习项目并完成一次计时后，这里会显示彩色统计图。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(displayed.filter { matches($0.activity.name, query: statisticsQuery) }) { summary in
                VStack(alignment: .leading, spacing: 12) {
                    activityRow(summary, largestDuration: largestDuration, order: summaries.map(\.id))
                    Divider()
                }
            }
            Text(L("勾选项目筛选趋势并合计。统计包含正在计时的时长；可在下方修改或补记记录。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rangeControl: some View {
        Picker(L("统计范围"), selection: $range) {
            Text(L("今天")).tag(1)
            Text(L("近 7 天")).tag(7)
            Text(L("近 30 天")).tag(30)
            Text(L("全部")).tag(0)
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityLabel(L("统计范围"))
        .accessibilityIdentifier("activityStatisticsRange")
    }

    private var sortControl: some View {
        HStack(spacing: 7) {
            Text(L("排序")).font(.caption).foregroundStyle(.secondary)
            Menu {
                Picker(L("排序"), selection: $sortOrder) {
                    ForEach(ActivityDurationSortOrder.allCases, id: \.self) { order in Text(order.title).tag(order) }
                }.pickerStyle(.inline).labelsHidden()
            } label: { Text(sortOrder.title).foregroundStyle(store.theme.foreground) }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(store.theme.foreground.opacity(0.035), in: RoundedRectangle(cornerRadius: DeskLayout.itemRadius))
            .overlay(RoundedRectangle(cornerRadius: DeskLayout.itemRadius).strokeBorder(.primary.opacity(0.10)))
            .accessibilityIdentifier("activityDurationSortOrder")
        }.fixedSize()
    }

    private var selectionActions: some View {
        HStack(spacing: 12) {
            Button(L("全选")) { selection.selectedForTotal = Set(store.activityTimers.activities.map(\.id)) }
            Button(L("清空选择")) { selection.selectedForTotal.removeAll() }
        }.controlSize(.small)
    }

    private func totalLabel(_ total: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("已选 %@ 项合计", "\(selection.selectedForTotal.count)")).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(ActivityDurationFormat.summary(total))
                .font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityIdentifier("activitySelectedTotal")
        }
    }

    private func summaryCard(total: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                DeskSectionHeading(title: L("累计时长"), symbol: "sum", theme: store.theme)
                Spacer(minLength: 8)
                Text(range == 0 ? L("累计范围：全部记录") : range == 1 ? L("累计范围：今天") : L("累计范围：近 %@ 天", "\(range)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("activityStatisticsScope")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { rangeControl.fixedSize(); Spacer(minLength: 0); sortControl }
                VStack(alignment: .leading, spacing: 10) { rangeControl; sortControl }
            }
            Divider().opacity(0.5)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom) { totalLabel(total).fixedSize(); Spacer(minLength: 16); selectionActions }
                VStack(alignment: .leading, spacing: 12) { totalLabel(total); selectionActions }
            }
        }
        .modifier(DeskSurface(theme: store.theme))
    }

    private func dailyChart(snapshot: ActivityStatisticsSnapshot) -> some View {
        let days = range == 0 ? 30 : range
        let points = snapshot.dailyDurations(days: days)
            .filter { selection.selectedForTotal.contains($0.activityID) && $0.duration > 0 }
        let today = Calendar.current.startOfDay(for: store.now)
        let first = Calendar.current.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? store.now
        let all = store.activityTimers.activities
        let legend = all.filter { selection.selectedForTotal.contains($0.id) } + all.filter { !selection.selectedForTotal.contains($0.id) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                DeskSectionHeading(title: L("每日学习趋势"), symbol: "chart.xyaxis.line", theme: store.theme)
                Spacer()
                Text(L("最近 %@ 天", "\(days)")).font(.caption).foregroundStyle(.secondary)
            }
            ActivityLegendLayout {
                ForEach(expandedLegend ? legend : Array(legend.prefix(6))) { activity in
                    Button {
                        if !selection.selectedForTotal.insert(activity.id).inserted { selection.selectedForTotal.remove(activity.id) }
                    } label: {
                        HStack(spacing: 6) {
                            ActivityChartBadge(activity: activity)
                            Text(activity.name).font(.callout).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(store.theme.foreground.opacity(0.025), in: RoundedRectangle(cornerRadius: DeskLayout.itemRadius))
                        .overlay(RoundedRectangle(cornerRadius: DeskLayout.itemRadius)
                            .strokeBorder(color(for: activity.id).opacity(selection.selectedForTotal.contains(activity.id) ? 0.24 : 0.06)))
                        .contentShape(Rectangle())
                        .opacity(selection.selectedForTotal.contains(activity.id) ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .help(L("点击筛选学习项目：%@", activity.name))
                    .accessibilityValue(selection.selectedForTotal.contains(activity.id) ? L("已选择") : L("未选择"))
                    .accessibilityIdentifier("activityLegend-\(activity.id)")
                }
            }
            if legend.count > 6 {
                Button(expandedLegend ? L("收起图例") : L("展开全部 %@ 个项目", "\(legend.count)")) { expandedLegend.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            Text(range == 0 ? L("趋势仅展示近 30 天；上方累计包含全部记录。悬停柱块可查看详情。")
                 : L("编号对应同一项目；悬停柱块可查看项目、日期和时长。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("点击柱子或日期可固定查看当天明细。")).font(.caption).foregroundStyle(.secondary)
                ActivityDailyChart(points: points, activities: store.activityTimers.activities,
                                   dateRange: first...end, days: days, selectedDay: selectedDay,
                                   onSelectDay: { selectedDay = $0 })
                    .equatable()
                    .frame(height: 210)
        }
        .modifier(DeskSurface(theme: store.theme))
    }

    private func dayDetails(_ day: Date, snapshot: ActivityStatisticsSnapshot) -> some View {
        let points = snapshot.dailyPoints.filter { $0.day == day && selection.selectedForTotal.contains($0.activityID) && $0.duration > 0 }
            .sorted { $0.duration == $1.duration ? $0.activityID.uuidString < $1.activityID.uuidString : $0.duration > $1.duration }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(day.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                Text(L("当前筛选项目合计：%@", ActivityDurationFormat.summary(points.reduce(0) { $0 + $1.duration })))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if range != 1 { Button(L("关闭明细")) { selectedDay = nil } }
            }
            ForEach(points) { point in
                if let activity = store.activityTimers.activities.first(where: { $0.id == point.activityID }) {
                    HStack {
                        ActivityChartBadge(activity: activity)
                        Text(activity.name).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text(ActivityDurationFormat.summary(point.duration)).monospacedDigit()
                        Button(L("查看记录")) { recordDay = day; recordProject = activity.id; section = 2; visibleSessions = 20 }
                    }
                }
            }
            if points.isEmpty { Text(L("当前筛选项目在这一天没有记录。")).foregroundStyle(.secondary) }
        }.modifier(DeskSurface(theme: store.theme, emphasized: true))
            .accessibilityIdentifier("activityDayDetails")
    }

    private func activityRow(_ summary: ActivityDurationSummary, largestDuration: TimeInterval, order: [UUID]) -> some View {
        let activity = summary.activity
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { selection.selectedForTotal.contains(activity.id) },
                    set: { if $0 { selection.selectedForTotal.insert(activity.id) } else { selection.selectedForTotal.remove(activity.id) } }
                )) {
                    HStack(spacing: 8) {
                        ActivityChartBadge(activity: activity)
                        Text(activity.name).font(.system(size: 13, weight: .medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        if activity.isArchived { Text(L("已归档")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                Text(ActivityDurationFormat.summary(summary.duration))
                    .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
                Button {
                    selection.beginEditing(activity, order: order)
                    inputError = nil
                } label: { Image(systemName: "pencil").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .disabled(store.activityIsBusy)
                .help(L("修改项目名称，保留计时记录"))
                .accessibilityLabel(L("修改%@的名称", "\(activity.name)"))
                .accessibilityIdentifier("activityRename-\(activity.id)")
                Menu {
                    Button(L("只看此项目")) { selection.selectedForTotal = [activity.id] }
                    Button(activity.isArchived ? L("恢复项目") : L("归档项目")) { perform(.archive(activity.id, !activity.isArchived), at: .page) }
                        .disabled(store.activityTimers.displayedSession?.activityID == activity.id)
                    Button(L("删除项目及记录"), role: .destructive) { selection.pendingDeletion = activity }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 30, height: 30) }
                    .buttonStyle(.borderless)
                    .disabled(store.activityIsBusy)
                    .help(L("删除项目及全部计时记录"))
                    .accessibilityLabel(L("管理项目：%@", activity.name))
                    .accessibilityIdentifier("activityDelete-\(activity.id)")
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color(for: activity.id).opacity(0.12))
                    Capsule().fill(color(for: activity.id))
                        .frame(width: geometry.size.width * min(1, summary.duration / largestDuration))
                }
            }
            .frame(height: 7)
            .opacity(selection.selectedForTotal.contains(activity.id) ? 1 : 0.45)
            .accessibilityLabel(activity.name + " · " + ActivityDurationFormat.summary(summary.duration))
            .help(activity.chartLabel + " " + activity.name + "\n" + ActivityDurationFormat.summary(summary.duration))
            if selection.editingActivityID == activity.id {
                HStack {
                    TextField(L("项目名称"), text: $selection.editedName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { renameActivity(activity) }
                        .accessibilityLabel(L("修改项目名称"))
                        .accessibilityIdentifier("activityRenameField")
                    Button(L("保存")) { renameActivity(activity) }
                        .disabled(store.activityIsBusy || selection.editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveActivityRename")
                    Button(L("取消")) { selection.cancelEditing(); report(nil, at: .setup) }
                        .accessibilityIdentifier("cancelActivityRename")
                }
                inlineError(for: .rename(activity.id))
            }
        }
    }

    private func renameActivity(_ activity: TimedActivity) {
        let submitted = selection.editedName
        Task {
            let error = await store.performActivityAction(.rename(activity.id, submitted))
            guard selection.editingActivityID == activity.id else { return }
            report(error, at: .rename(activity.id))
            if error == nil, selection.editedName == submitted { selection.cancelEditing() }
        }
    }

    private func deleteActivity(_ activity: TimedActivity) {
        Task {
            report(await store.performActivityAction(.delete(activity.id)), at: .page)
            synchronizeSelection()
            selection.pendingDeletion = nil
        }
    }

    private var records: some View {
        let filtered = recentSessions.filter { session in
            (recordProject == nil || session.activityID == recordProject)
            && matches(name(for: session.activityID) + " " + (session.note ?? ""), query: recordQuery)
            && (recordDay.map { day in
                session.duration(at: store.now, in: DateInterval(start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day)!)) > 0
            } ?? true)
        }
        let shown = Array(filtered.prefix(visibleSessions))
        let grouped = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.startedAt) }
        return Group {
            HStack {
                TextField(L("查找项目或本次内容"), text: $recordQuery).textFieldStyle(.roundedBorder)
                Picker(L("学习项目"), selection: $recordProject) {
                    Text(L("全部项目")).tag(nil as UUID?)
                    ForEach(store.activityTimers.activities) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            HStack {
                Toggle(L("指定日期"), isOn: Binding(get: { recordDay != nil }, set: { recordDay = $0 ? Calendar.current.startOfDay(for: store.now) : nil }))
                if recordDay != nil {
                    DatePicker(L("日期"), selection: Binding(get: { recordDay ?? store.now }, set: { recordDay = Calendar.current.startOfDay(for: $0) }), in: ...store.now, displayedComponents: .date)
                }
                Spacer()
                Button(L("清除记录筛选")) { recordDay = nil; recordProject = nil; recordQuery = ""; visibleSessions = 20 }
            }
            if recordDay != nil {
                Text(L("包含跨日记录的当天有效片段；修改时长和备注作用于整次记录。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                DeskSectionHeading(title: L("计时记录 · %@ 次", "\(filtered.count)"), symbol: "clock.arrow.circlepath", theme: store.theme)
                Spacer()
                Button(L("补记学习")) { addingRecord = true }
                    .disabled(store.activityIsBusy || store.activityTimers.activities.isEmpty)
                    .accessibilityIdentifier("addActivityRecord")
            }
            if filtered.isEmpty {
                Text(L("结束一次计时后，会在这里显示记录。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(grouped.keys.sorted(by: >), id: \.self) { day in
                Text(L("开始日期：%@", day.formatted(date: .abbreviated, time: .omitted))).font(.headline).padding(.top, 8)
            ForEach(grouped[day] ?? []) { session in
                VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RoundedRectangle(cornerRadius: 2).fill(color(for: session.activityID))
                        .frame(width: 4, height: 36)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name(for: session.activityID)).fontWeight(.medium)
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + session.mode.title)
                            .font(.caption).foregroundStyle(.secondary)
                        if session.correctedDuration != nil {
                            Text(L("已修改时长 · 原计时 %@", ActivityDurationFormat.summary(session.recordedDuration)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let note = session.note, !note.isEmpty { Text(note).font(.callout).fixedSize(horizontal: false, vertical: true) }
                        if let day = recordDay {
                            let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                            Text(L("当天有效时长：%@", ActivityDurationFormat.summary(session.duration(at: store.now, in: .init(start: day, end: end)))))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(ActivityDurationFormat.summary(session.savedDuration)).monospacedDigit()
                    Button(L("修改时长与备注")) { selection.editingSession = session }
                        .disabled(store.activityTimers.pendingCountdownSessionID == session.id)
                        .accessibilityLabel(L("修改%@的学习时长", name(for: session.activityID)))
                }
                Divider()
                }
            }
            }
            if filtered.count > visibleSessions {
                Button(L("显示更多记录")) { visibleSessions += 20 }
            }
        }
    }

    private func synchronizeSelection() {
        selection.synchronize(with: store.activityTimers)
        if let id = selection.activityID, store.activityTimers.activities.first(where: { $0.id == id })?.isArchived != false { selection.activityID = nil }
        if let id = recordProject, !store.activityTimers.activities.contains(where: { $0.id == id }) { recordProject = nil }
        if case .rename(let id) = inputContext, selection.editingActivityID != id {
            inputError = nil
            inputContext = .setup
        }
    }

    private func restorePreferences() {
        guard !restoredPreferences, store.activityDataReady else { return }
        section = initialSection ?? store.activityExperience.section.rawValue
        range = store.activityExperience.range
        sortOrder = store.activityExperience.sortOrder
        synchronizeSelection()
        if let saved = store.activityExperience.selectedActivityIDs {
            selection.selectedForTotal = saved.intersection(Set(store.activityTimers.activities.map(\.id)))
        }
        creatingProject = store.activityTimers.activities.isEmpty
        previousSessionID = store.activityTimers.displayedSession?.id
        restoredPreferences = true
    }

    private func name(for id: UUID) -> String {
        store.activityTimers.activities.first { $0.id == id }?.name ?? L("项目")
    }

    private func addActivity() {
        let submitted = newName
        Task {
            report(await store.performActivityAction(.add(submitted)), at: .setup)
            if inputError == nil {
                selection.activityID = store.activityTimers.activities.last?.id
                if newName == submitted { newName = "" }
            }
        }
    }

    private func start() {
        guard let id = selection.activityID else { return }
        var duration: TimeInterval?
        if mode == .countdown {
            guard let h = Int(hours), let m = Int(minutes), let s = Int(seconds),
                  (0...168).contains(h), (0...59).contains(m), (0...59).contains(s) else {
                report(L("请输入有效时长：小时为 0–168，分钟和秒为 0–59。"), at: .setup)
                return
            }
            duration = Double(h * 3600 + m * 60 + s)
        }
        if store.activityTimers.activeSession != nil { perform(.switchActivity(id, mode, duration), at: .setup) }
        else { perform(.start(id, mode, duration), at: .setup) }
    }

    private func perform(_ action: ActivityTimerAction, at context: ActivityInputContext) {
        Task { report(await store.performActivityAction(action), at: context) }
    }

    private func report(_ message: String?, at context: ActivityInputContext) {
        inputContext = context
        inputError = message
    }

    @ViewBuilder private func inlineError(for context: ActivityInputContext) -> some View {
        if inputContext == context, let inputError {
            ActivityInlineError(message: inputError).accessibilityIdentifier("activityInputError")
        }
    }
}

private enum ActivityInputContext: Equatable { case setup, timer, rename(UUID), page }

private struct ActivityInlineError: View {
    var message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The legend is small enough to lay out directly; nested lazy grids can leave
/// blank rows when the surrounding scroll view changes language or identity.
private struct ActivityLegendLayout: Layout {
    private let spacing: CGFloat = 6

    private func metrics(width: CGFloat, subviews: Subviews) -> (columns: Int, cellWidth: CGFloat, heights: [CGFloat]) {
        let width = width.isFinite ? max(0, width) : 210
        let columns = max(1, Int(min(CGFloat(max(1, subviews.count)), floor((width + spacing) / (210 + spacing)))))
        let cellWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for index in subviews.indices {
            heights[index / columns] = max(heights[index / columns], subviews[index].sizeThatFits(.init(width: cellWidth, height: nil)).height)
        }
        return (columns, cellWidth, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? 210
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : 210
        let layout = metrics(width: width, subviews: subviews)
        return CGSize(width: width, height: layout.heights.reduce(0, +) + CGFloat(max(0, layout.heights.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in layout.heights.indices {
            for column in 0..<layout.columns {
                let index = row * layout.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (layout.cellWidth + spacing), y: y),
                                     anchor: .topLeading, proposal: .init(width: layout.cellWidth, height: layout.heights[row]))
            }
            y += layout.heights[row] + spacing
        }
    }
}

private enum ActivityChartPalette {
    static func color(_ index: Int) -> Color {
        let colors: [Color] = [Color(red: 0.30, green: 0.62, blue: 0.92),
                               Color(red: 0.30, green: 0.73, blue: 0.62),
                               Color(red: 0.92, green: 0.57, blue: 0.35),
                               Color(red: 0.68, green: 0.53, blue: 0.88),
                               Color(red: 0.88, green: 0.44, blue: 0.55),
                               Color(red: 0.78, green: 0.69, blue: 0.28),
                               Color(red: 0.34, green: 0.72, blue: 0.80),
                               Color(red: 0.76, green: 0.54, blue: 0.69)]
        return index < colors.count ? colors[max(0, index)]
            : Color(hue: (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.85)
    }
}

private struct ActivityChartBadge: View {
    var activity: TimedActivity

    var body: some View {
        Text(activity.chartLabel)
            .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(ActivityChartPalette.color(activity.colorIndex ?? 0), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

struct ActivityDailyChart: View, Equatable {
    var points: [ActivityDailyDuration]
    var activities: [TimedActivity]
    var dateRange: ClosedRange<Date>
    var days: Int
    var selectedDay: Date? = nil
    var onSelectDay: ((Date) -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.activities == rhs.activities && lhs.dateRange == rhs.dateRange && lhs.days == rhs.days
            && lhs.selectedDay == rhs.selectedDay
            && (lhs.onSelectDay == nil) == (rhs.onSelectDay == nil)
    }

    var body: some View {
        let segments = ActivityDailyChartSegment.stacking(points)
        let activityByID = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        let largestDay = segments.map(\.upperBound).max() ?? 0
        Chart(segments) { segment in
            let dates = segment.dateRange()
            RectangleMark(xStart: .value(L("日期"), dates.lowerBound),
                          xEnd: .value(L("日期"), dates.upperBound),
                          yStart: .value(L("小时"), segment.lowerBound / 3600),
                          yEnd: .value(L("小时"), segment.upperBound / 3600))
                .foregroundStyle(by: .value(L("项目"), segment.point.activityID.uuidString))
                .accessibilityLabel(Text((activityByID[segment.point.activityID]?.name ?? L("项目"))
                                         + " · " + segment.point.day.formatted(date: .abbreviated, time: .omitted)))
                .accessibilityValue(Text(ActivityDurationFormat.summary(segment.point.duration)))
        }
        .chartForegroundStyleScale(domain: activities.map { $0.id.uuidString },
                                   range: activities.map { ActivityChartPalette.color($0.colorIndex ?? 0) })
        .chartLegend(.hidden)
        .chartXScale(domain: dateRange)
        .chartYScale(domain: 0...max(1, largestDay / 3600))
        .chartYAxisLabel(L("小时"))
        .chartYAxis {
            AxisMarks(position: .trailing) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(0.22))
                AxisValueLabel().font(.system(size: 10))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days <= 7 ? 1 : 7)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(.secondary.opacity(0.20))
                AxisTick().foregroundStyle(.secondary.opacity(0.25))
                AxisValueLabel(format: .dateTime.month().day())
                    .font(.system(size: 10))
            }
        }
        .chartOverlay { proxy in
            ActivityDailyChartOverlay(segments: segments, activities: activityByID, dateRange: dateRange, proxy: proxy,
                                      selectedDay: selectedDay, onSelectDay: onSelectDay)
        }
        .accessibilityIdentifier("activityDailyChart")
    }
}

private struct ActivityDailyChartOverlay: View {
    let segments: [ActivityDailyChartSegment]
    let activities: [UUID: TimedActivity]
    let dateRange: ClosedRange<Date>
    let proxy: ChartProxy
    let selectedDay: Date?
    let onSelectDay: ((Date) -> Void)?
    @State private var hoveredID: String?
    @State private var tooltipSize = CGSize.zero
    @State private var geometryCache = ActivityChartGeometryCache()

    var body: some View {
            GeometryReader { geometry in
                let plot = geometry[proxy.plotAreaFrame]
                let regions = geometryCache.value(segments: segments, activities: activities, dateRange: dateRange, plot: plot) {
                    makeRegions(for: segments, activities: activities, proxy: proxy, plot: plot)
                }
                let hovered = hoveredID.flatMap { geometryCache.region(id: $0) }
                ZStack(alignment: .topLeading) {
                    if let selectedDay, let rect = dayFrame(selectedDay, plot: plot) {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.065))
                            .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    ActivityChartPointerTracking(regions: regions, plot: plot, detail: hovered?.detail,
                                                 dateRange: dateRange, selectedDay: selectedDay, onSelectDay: onSelectDay) { hoveredID = $0 }
                    ActivityChartDecorations(regions: regions).equatable()
                    if let hovered {
                        Rectangle()
                            .strokeBorder(.primary.opacity(0.9), lineWidth: 2)
                            .frame(width: hovered.frame.width, height: hovered.frame.height)
                            .position(x: hovered.frame.midX, y: hovered.frame.midY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        tooltip(for: hovered)
                            .frame(width: tooltipWidth(for: hovered.frame, in: geometry.size), alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { size in
                                Color.clear.preference(key: ActivityChartTooltipSize.self, value: size.size)
                            })
                            .offset(tooltipOffset(for: hovered.frame, plot: plot, in: geometry.size))
                            .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(ActivityChartTooltipSize.self) { tooltipSize = $0 }
            }
        .onDisappear { hoveredID = nil }
    }

    private func dayFrame(_ day: Date, plot: CGRect) -> CGRect? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard start >= dateRange.lowerBound, start < dateRange.upperBound,
              let end = calendar.date(byAdding: .day, value: 1, to: start),
              let left = proxy.position(forX: start), let right = proxy.position(forX: end) else { return nil }
        return CGRect(x: plot.minX + left, y: plot.minY, width: right - left, height: plot.height).intersection(plot)
    }

    private func makeRegions(for segments: [ActivityDailyChartSegment], activities: [UUID: TimedActivity], proxy: ChartProxy, plot: CGRect) -> [ActivityChartRegion] {
        segments.compactMap { segment in
            let dates = segment.dateRange()
            guard let activity = activities[segment.point.activityID],
                  let left = proxy.position(forX: dates.lowerBound), let right = proxy.position(forX: dates.upperBound),
                  let top = proxy.position(forY: segment.upperBound / 3600),
                  let bottom = proxy.position(forY: segment.lowerBound / 3600) else { return nil }
            let rect = CGRect(x: plot.minX + left, y: plot.minY + top, width: right - left, height: bottom - top)
                .intersection(plot)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
            return ActivityChartRegion(segment: segment, activity: activity, frame: rect)
        }
    }

    private func tooltip(for region: ActivityChartRegion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                ActivityChartBadge(activity: region.activity)
                Text(region.activity.name).font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(region.segment.point.day.formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(.secondary)
            Text(ActivityDurationFormat.summary(region.segment.point.duration))
                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(region.detail)
        .accessibilityIdentifier("activityChartTooltip")
    }

    private func tooltipWidth(for rect: CGRect, in size: CGSize) -> CGFloat {
        min(300, max(180, max(rect.minX - 16, size.width - rect.maxX - 16)), max(0, size.width - 16))
    }

    private func tooltipOffset(for rect: CGRect, plot: CGRect, in size: CGSize) -> CGSize {
        let width = tooltipWidth(for: rect, in: size)
        let height = tooltipSize.height
        let x = rect.maxX + 8 + width <= size.width ? rect.maxX + 8 : rect.minX - width - 8
        let y = rect.midY - height / 2
        return CGSize(width: max(8, min(x, size.width - width - 8)),
                      height: max(plot.minY, min(y, plot.maxY - height)))
    }
}

/// Static marks do not depend on hover state. Moving across a chart updates
/// one highlight and one tooltip instead of changing every mark's border.
private struct ActivityChartDecorations: View, Equatable {
    let regions: [ActivityChartRegion]

    var body: some View {
        ForEach(regions) { region in
            Rectangle()
                .strokeBorder(.primary.opacity(0.2), lineWidth: 0.5)
                .frame(width: region.frame.width, height: region.frame.height)
                .position(x: region.frame.midX, y: region.frame.midY)
            if region.frame.height >= 16 && region.frame.width >= CGFloat(region.activity.chartLabel.count * 7 + 6) {
                Text(region.activity.chartLabel)
                    .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.black.opacity(0.85))
                    .position(x: region.frame.midX, y: region.frame.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private final class ActivityChartGeometryCache {
    private var segments: [ActivityDailyChartSegment]?
    private var activities: [UUID: TimedActivity]?
    private var dateRange: ClosedRange<Date>?
    private var plot: CGRect?
    private var cached: [ActivityChartRegion] = []
    private var byID: [String: ActivityChartRegion] = [:]

    func region(id: String) -> ActivityChartRegion? { byID[id] }

    func value(segments: [ActivityDailyChartSegment], activities: [UUID: TimedActivity],
               dateRange: ClosedRange<Date>, plot: CGRect, make: () -> [ActivityChartRegion]) -> [ActivityChartRegion] {
        if self.plot != plot || self.dateRange != dateRange || self.segments != segments || self.activities != activities {
            cached = make()
            byID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
            self.segments = segments
            self.activities = activities
            self.dateRange = dateRange
            self.plot = plot
        }
        return cached
    }
}

private struct ActivityChartTooltipSize: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}


private struct ActivityChartPointerTracking: NSViewRepresentable {
    var regions: [ActivityChartRegion]
    var plot: CGRect
    var detail: String?
    var dateRange: ClosedRange<Date>?
    var selectedDay: Date?
    var onSelectDay: ((Date) -> Void)?
    var onHover: (String?) -> Void

    func makeNSView(context: Context) -> ActivityChartPointerView { ActivityChartPointerView() }

    func updateNSView(_ view: ActivityChartPointerView, context: Context) {
        view.configure(regions: regions, plot: plot, dateRange: dateRange, selectedDay: selectedDay,
                       onSelectDay: onSelectDay, onHover: onHover)
        view.setAccessibilityHelp(detail)
    }
}

final class ActivityChartPointerView: NSView {
    private(set) var regions: [ActivityChartRegion] = []
    private(set) var plot = CGRect.zero
    private(set) var hoverChangeCount = 0
    private var onHover: ((String?) -> Void)?
    private var hoveredID: String?
    private var lastWindowLocation: CGPoint?
    private var pointerTrackingArea: NSTrackingArea?
    private var hitIndex = ActivityChartHitIndex()
    private(set) var hitIndexBuildCount = 0
    private var dateRange: ClosedRange<Date>?
    private var selectedDay: Date?
    private var onSelectDay: ((Date) -> Void)?
    private var dateActionsInstalled = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { onSelectDay != nil }

    func configure(regions: [ActivityChartRegion], plot: CGRect, dateRange: ClosedRange<Date>? = nil,
                   selectedDay: Date? = nil, onSelectDay: ((Date) -> Void)? = nil,
                   onHover: @escaping (String?) -> Void) {
        if self.regions != regions || self.plot != plot {
            self.regions = regions
            self.plot = plot
            hitIndex = ActivityChartHitIndex(regions: regions, plot: plot)
            hitIndexBuildCount += 1
        }
        self.onHover = onHover
        self.dateRange = dateRange
        self.selectedDay = selectedDay
        self.onSelectDay = onSelectDay
        setAccessibilityElement(onSelectDay != nil)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("每日学习趋势"))
        setAccessibilityValue(selectedDay?.formatted(date: .abbreviated, time: .omitted))
        if onSelectDay != nil, !dateActionsInstalled {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: L("前一天")) { [weak self] in self?.moveSelection(by: -1) ?? false },
                NSAccessibilityCustomAction(name: L("后一天")) { [weak self] in self?.moveSelection(by: 1) ?? false },
                NSAccessibilityCustomAction(name: L("查看当天明细")) { [weak self] in self?.selectCurrentDay() ?? false }
            ])
            dateActionsInstalled = true
        } else if onSelectDay == nil, dateActionsInstalled {
            setAccessibilityCustomActions(nil)
            dateActionsInstalled = false
        }
        // Layout/filter changes can move a different block under a stationary pointer.
        refreshHover(deferred: true)
    }

    private func refreshHover(deferred: Bool = false) {
        let id = lastWindowLocation.flatMap { location in
            hitIndex.hitTest(convert(location, from: nil))?.id
        }
        guard id != hoveredID else { return }
        hoveredID = id
        hoverChangeCount += 1
        if deferred {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hoveredID == id else { return }
                self.onHover?(id)
            }
        } else {
            onHover?(id)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
        refreshHover(deferred: true)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        lastWindowLocation = event.locationInWindow
        refreshHover()
    }
    override func mouseExited(with event: NSEvent) {
        lastWindowLocation = nil
        refreshHover()
    }

    /// The selection target spans the entire day column, including empty days
    /// and the date axis. It is independent of precision hover hit testing.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let range = dateRange, onSelectDay != nil,
              plot.width > 0, point.x >= plot.minX, point.x <= plot.maxX,
              point.y >= plot.minY, point.y <= bounds.maxY else { return }
        window?.makeFirstResponder(self)
        let fraction = min(1, max(0, (point.x - plot.minX) / plot.width))
        let instant = range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) * fraction)
        select(day: min(instant, range.upperBound.addingTimeInterval(-0.001)))
    }

    override func keyDown(with event: NSEvent) {
        guard onSelectDay != nil else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 126: _ = moveSelection(by: -1)
        case 124, 125: _ = moveSelection(by: 1)
        case 36, 49: _ = selectCurrentDay()
        default: super.keyDown(with: event)
        }
    }

    @discardableResult
    private func select(day: Date) -> Bool {
        guard let range = dateRange, let onSelectDay else { return false }
        let normalized = Calendar.current.startOfDay(for: day)
        guard normalized >= range.lowerBound, normalized < range.upperBound else { return false }
        selectedDay = normalized
        setAccessibilityValue(normalized.formatted(date: .abbreviated, time: .omitted))
        onSelectDay(normalized)
        return true
    }

    private func selectCurrentDay() -> Bool {
        guard let range = dateRange else { return false }
        return select(day: selectedDay ?? range.upperBound.addingTimeInterval(-0.001))
    }

    private func moveSelection(by offset: Int) -> Bool {
        guard let range = dateRange else { return false }
        let current = selectedDay ?? Calendar.current.startOfDay(for: range.upperBound.addingTimeInterval(-0.001))
        guard let next = Calendar.current.date(byAdding: .day, value: offset, to: current) else { return false }
        return select(day: next)
    }
}

struct ActivityRecordEditor: View {
    @ObservedObject var store: PlanStore
    var session: ActivityTimerSession?
    @Environment(\.dismiss) private var dismiss
    @State private var activityID: UUID?
    @State private var startedAt: Date
    @State private var hours: String
    @State private var minutes: String
    @State private var seconds: String
    @State private var error: String?
    @State private var note: String

    init(store: PlanStore, session: ActivityTimerSession? = nil) {
        self.store = store
        self.session = session
        _activityID = State(initialValue: session?.activityID ?? store.activityTimers.activities.first?.id)
        _startedAt = State(initialValue: session?.startedAt ?? store.now.addingTimeInterval(-1800))
        let duration = Int(floor(session?.savedDuration ?? 1800))
        _hours = State(initialValue: "\(duration / 3600)")
        _minutes = State(initialValue: "\(duration % 3600 / 60)")
        _seconds = State(initialValue: "\(duration % 60)")
        _note = State(initialValue: session?.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(session == nil ? L("补记学习") : L("修改学习时长")).font(.title2.weight(.semibold))
            if let session {
                Text(store.activityTimers.activities.first { $0.id == session.activityID }?.name ?? L("项目"))
                    .font(.headline)
                Text(session.startedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.callout).foregroundStyle(.secondary)
                Text(L("原始计时：%@。从开始处保留填写的有效时长，暂停时间仍不计入；可随时恢复原时长。", ActivityDurationFormat.summary(session.recordedDuration)))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(L("学习项目"), selection: $activityID) {
                    ForEach(store.activityTimers.activities) { activity in
                        Text(activity.name).tag(Optional(activity.id))
                    }
                }
                ClockDrivenContent(clock: store.clock) {
                    DatePicker(L("开始时间"), selection: $startedAt, in: ...store.now,
                               displayedComponents: [.date, .hourAndMinute])
                }
            }
            HStack {
                Text(L("学习时长"))
                field(L("小时"), value: $hours, identifier: "recordDurationHours")
                field(L("分"), value: $minutes, identifier: "recordDurationMinutes")
                field(L("秒"), value: $seconds, identifier: "recordDurationSeconds")
            }
            TextField(L("本次内容（可选）"), text: $note, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("activityRecordNote")
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("activityRecordError")
            }
            HStack {
                if let session {
                    Button(L("恢复原时长")) {
                        let duration = Int(floor(session.recordedDuration))
                        hours = "\(duration / 3600)"; minutes = "\(duration % 3600 / 60)"; seconds = "\(duration % 60)"
                    }
                }
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存"), action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("saveActivityRecord")
            }
        }
        .padding(24)
        .frame(width: 490)
        .modifier(ThemeSurface(store: store))
        .disabled(store.activityIsBusy)
    }

    private func field(_ label: String, value: Binding<String>, identifier: String) -> some View {
        HStack(spacing: 4) {
            TextField(label, text: value).textFieldStyle(.roundedBorder).frame(width: 55)
                .accessibilityLabel(L("学习时长%@", label)).accessibilityIdentifier(identifier)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard let h = Int(hours), let m = Int(minutes), let s = Int(seconds),
              (0...1_000_000).contains(h), (0...59).contains(m), (0...59).contains(s) else {
            error = L("请输入有效时长：小时不能为负，分钟和秒为 0–59。")
            return
        }
        let duration = Double(h * 3600 + m * 60 + s)
        let action: ActivityTimerAction
        if let session {
            // Saving a note must not round a fractional recorded duration or
            // turn an unchanged time into a correction.
            action = duration == floor(session.savedDuration) ? .note(session.id, note) : .editRecord(session.id, duration, note)
        }
        else if let activityID { action = .addNotedRecord(activityID, startedAt, duration, note) }
        else {
            error = L("请选择一个项目。")
            return
        }
        Task {
            error = await store.performActivityAction(action)
            if error == nil { dismiss() }
        }
    }
}

struct ActivityTimerStrip: View {
    @ObservedObject var store: PlanStore
    var onOpen: (() -> Void)? = nil

    var body: some View {
        ClockDrivenContent(clock: store.clock, enabled: store.activityTimers.activeSession?.runningSince != nil) { content }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Button {
                if let onOpen { onOpen() }
                else { store.rememberActivitySection(.timer); store.onShowTimers?() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let session = store.activityTimers.displayedSession {
                        Text(store.activityTimers.activities.first { $0.id == session.activityID }?.name ?? L("项目"))
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(session.isAwaitingCompletion ? L("已到时 · 可继续专注") : (session.isPaused ? L("已暂停 · ") : "\(session.mode.title) · ") + ActivityDurationFormat.clock(session.mode == .countdown ? session.remaining(at: store.activityDisplayNow) : session.elapsed(at: store.activityDisplayNow), roundUp: session.mode == .countdown))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    } else {
                        Label(L("事项计时与累计时长"), systemImage: "timer")
                            .font(.system(size: 11, weight: .medium))
                    }
                    if store.activityTimerError != nil {
                        Text(L("计时记录未保存，点击查看")).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("打开事项计时与累计时长"))
            if let session = store.activityTimers.activeSession {
                Button { Task { await store.performActivityAction(.togglePause) } } label: {
                    Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(session.isPaused ? L("继续事项计时") : L("暂停事项计时"))
                .disabled(store.activityIsBusy)
            } else {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
