import SwiftUI

struct ActivityTimersView: View {
    @ObservedObject var store: PlanStore
    @State private var newName = ""
    @State private var selectedActivity: UUID?
    @State private var mode: ActivityTimerMode = .stopwatch
    @State private var hours = "0"
    @State private var minutes = "25"
    @State private var seconds = "0"
    @State private var range = 0
    @State private var sortOrder: ActivityDurationSortOrder = .descending
    @State private var editingActivityID: UUID?
    @State private var editedName = ""
    @State private var pendingDeletion: TimedActivity?
    @State private var selectedForTotal: Set<UUID> = []
    @State private var visibleSessions = 20
    @State private var inputError: String?

    private var interval: DateInterval? {
        guard range > 0 else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: store.now)
        let start = calendar.date(byAdding: .day, value: -(range - 1), to: today) ?? today
        return DateInterval(start: start, end: store.now)
    }

    private var recentSessions: [ActivityTimerSession] {
        store.activityTimers.sessions.filter { $0.endedAt != nil }.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("事项计时")).font(.system(size: 25, weight: .bold))
                    Text(L("给每一次投入留下一份记录")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("今日计划")) { store.onShowPlan?() }
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let message = inputError ?? store.activityTimerError {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let session = store.activityTimers.displayedSession {
                        activeTimer(session)
                    }
                    setup
                    statistics
                    records
                }
                .padding(24)
            }
        }
        .frame(minWidth: 680, minHeight: 540)
        .modifier(ThemeSurface(store: store))
        .id(store.language)
        .alert(L("删除计时事项？"), isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { activity in
            Button(L("取消"), role: .cancel) { pendingDeletion = nil }
            Button(L("删除事项及记录"), role: .destructive) { deleteActivity(activity) }
        } message: { activity in
            Text(L("将删除“%@”及其全部计时记录和累计时长，无法撤销。", "\(activity.name)")
                 + (store.activityTimers.activeSession?.activityID == activity.id ? L("当前计时也将停止。") : "")
                 + L("如果只是打错字，可取消后点击铅笔修改名称，保留已有记录。"))
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("开始一次计时")).font(.headline)
            HStack {
                TextField(L("新事项名称，例如：阅读、运动"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addActivity)
                    .accessibilityIdentifier("newActivityName")
                Button(L("添加事项"), action: addActivity)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if store.activityTimers.activities.isEmpty {
                Text(L("先添加一个事项，之后每次选择它计时，时长会自动累计。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker(L("计时事项"), selection: $selectedActivity) {
                    Text(L("请选择事项")).tag(nil as UUID?)
                    ForEach(store.activityTimers.activities) { activity in
                        Text(activity.name).tag(Optional(activity.id))
                    }
                }
                Picker(L("计时方式"), selection: $mode) {
                    ForEach(ActivityTimerMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
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
                    Button(L("开始计时"), action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedActivity == nil || store.activityTimers.activeSession != nil)
                }
            }
            Text(L("每次只能运行一个计时。暂停不计时；运行期间的睡眠、退出应用时间计入时长，重启后继续。离开前可先暂停。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
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
                    .font(.callout).foregroundStyle(isDue ? accent : .secondary)
                Spacer()
                Text(session.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Text(name(for: session.activityID)).font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(isDue ? L("已到时") : ActivityDurationFormat.clock(session.mode == .countdown ? session.remaining(at: store.now) : session.elapsed(at: store.now), roundUp: session.mode == .countdown))
                    .font(.system(size: isDue ? 32 : 42, weight: .light, design: .rounded)).monospacedDigit()
                    .foregroundStyle(isDue ? accent : .primary)
                    .accessibilityIdentifier("activityTimerClock")
                if !isDue {
                    Text(session.mode == .countdown ? L("剩余") : L("已用时")).foregroundStyle(.secondary)
                }
                Spacer()
                if isDue {
                    Button(L("+5 分钟")) { inputError = store.extendActivityCountdown() }
                        .help(L("从现在开始，为这个事项再计时 5 分钟"))
                } else {
                    Button(session.isPaused ? L("继续") : L("暂停")) { inputError = store.toggleActivityTimerPause() }
                }
                Button(isDue ? L("完成") : L("结束并记录")) { inputError = store.finishActivityTimer() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            }
            if session.targetDuration != nil {
                ProgressView(value: session.progress(at: store.now)).tint(accent)
            }
            if isDue {
                Text(L("这段专注已计入累计时长。准备好后，可以完成或再专注 5 分钟。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("累计时长")).font(.headline)
            Picker(L("统计范围"), selection: $range) {
                Text(L("今天")).tag(1)
                Text(L("近 7 天")).tag(7)
                Text(L("近 30 天")).tag(30)
                Text(L("全部")).tag(0)
            }
            .pickerStyle(.segmented)
            HStack {
                Picker(L("排序"), selection: $sortOrder) {
                    ForEach(ActivityDurationSortOrder.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("activityDurationSortOrder")
                Spacer()
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("已选 %@ 项合计", "\(selectedForTotal.count)")).font(.caption).foregroundStyle(.secondary)
                    Text(ActivityDurationFormat.summary(store.activityTimers.total(for: selectedForTotal, at: store.now, in: interval)))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                }
                Spacer()
                Button(L("全选")) { selectedForTotal = Set(store.activityTimers.activities.map(\.id)) }
                Button(L("清空选择")) { selectedForTotal.removeAll() }
            }
            ForEach(store.activityTimers.durationSummaries(at: store.now, in: interval, order: sortOrder)) { summary in
                activityRow(summary)
                Divider()
            }
            Text(L("勾选多个事项可合计；排序依据当前统计范围内的用时。铅笔可修改名称并保留记录，废纸篓可删除事项及记录。统计包含正在进行的时长，暂停时间不计入。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func activityRow(_ summary: ActivityDurationSummary) -> some View {
        let activity = summary.activity
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { selectedForTotal.contains(activity.id) },
                    set: { if $0 { selectedForTotal.insert(activity.id) } else { selectedForTotal.remove(activity.id) } }
                )) { Text(activity.name).fixedSize(horizontal: false, vertical: true) }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                Text(ActivityDurationFormat.summary(summary.duration))
                    .monospacedDigit().foregroundStyle(.secondary)
                Button {
                    editingActivityID = activity.id
                    editedName = activity.name
                    inputError = nil
                } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help(L("修改事项名称，保留计时记录"))
                .accessibilityLabel(L("修改%@的名称", "\(activity.name)"))
                Button { pendingDeletion = activity } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L("删除事项及全部计时记录"))
                    .accessibilityLabel(L("删除%@", "\(activity.name)"))
            }
            if editingActivityID == activity.id {
                HStack {
                    TextField(L("事项名称"), text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { renameActivity(activity) }
                        .accessibilityLabel(L("修改事项名称"))
                    Button(L("保存")) { renameActivity(activity) }
                        .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L("取消")) { editingActivityID = nil }
                }
            }
        }
    }

    private func renameActivity(_ activity: TimedActivity) {
        inputError = store.renameTimedActivity(id: activity.id, name: editedName)
        if inputError == nil { editingActivityID = nil }
    }

    private func deleteActivity(_ activity: TimedActivity) {
        inputError = store.deleteTimedActivity(id: activity.id)
        if inputError == nil {
            selectedForTotal.remove(activity.id)
            if selectedActivity == activity.id { selectedActivity = nil }
            if editingActivityID == activity.id { editingActivityID = nil }
        }
        pendingDeletion = nil
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("计时记录 · %@ 次", "\(recentSessions.count)")).font(.headline)
            if recentSessions.isEmpty {
                Text(L("结束一次计时后，会在这里显示记录。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(recentSessions.prefix(visibleSessions)) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name(for: session.activityID)).fontWeight(.medium)
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + session.mode.title)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ActivityDurationFormat.summary(session.savedDuration)).monospacedDigit()
                }
                Divider()
            }
            if recentSessions.count > visibleSessions {
                Button(L("显示更多记录")) { visibleSessions += 20 }
            }
        }
    }

    private func name(for id: UUID) -> String {
        store.activityTimers.activities.first { $0.id == id }?.name ?? L("事项")
    }

    private func addActivity() {
        inputError = store.addTimedActivity(name: newName)
        if inputError == nil {
            selectedActivity = store.activityTimers.activities.last?.id
            newName = ""
        }
    }

    private func start() {
        guard let id = selectedActivity else { return }
        var duration: TimeInterval?
        if mode == .countdown {
            guard let h = Int(hours), let m = Int(minutes), let s = Int(seconds),
                  (0...168).contains(h), (0...59).contains(m), (0...59).contains(s) else {
                inputError = L("请输入有效时长：小时为 0–168，分钟和秒为 0–59。")
                return
            }
            duration = Double(h * 3600 + m * 60 + s)
        }
        inputError = store.startActivityTimer(activityID: id, mode: mode, duration: duration)
    }
}

struct ActivityTimerStrip: View {
    @ObservedObject var store: PlanStore

    var body: some View {
        HStack(spacing: 8) {
            Button { store.onShowTimers?() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let session = store.activityTimers.displayedSession {
                        Text(store.activityTimers.activities.first { $0.id == session.activityID }?.name ?? L("事项"))
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(session.isAwaitingCompletion ? L("已到时 · 可继续专注") : (session.isPaused ? L("已暂停 · ") : "\(session.mode.title) · ") + ActivityDurationFormat.clock(session.mode == .countdown ? session.remaining(at: store.now) : session.elapsed(at: store.now), roundUp: session.mode == .countdown))
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
                Button { store.toggleActivityTimerPause() } label: {
                    Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(session.isPaused ? L("继续事项计时") : L("暂停事项计时"))
            } else {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
