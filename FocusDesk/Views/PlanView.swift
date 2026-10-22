import SwiftUI

struct PlanView: View {
    @ObservedObject var store: PlanStore
    @State private var editingID: UUID?
    @State private var newTask: PlanTask?
    @State private var retainedNewTask: PlanTask?
    @State private var drafts: [UUID: TaskDraft] = [:]
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = actionError ?? store.errorMessage {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button {
                        actionError = nil
                        store.clearError()
                    } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                }
                .padding(14)
                .background(Color.orange.opacity(0.08))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let task = newTask {
                            editor(for: task, isNew: true)
                                .id("new-task")
                        } else if retainedNewTask != nil {
                            HStack {
                                Label("新增草稿已保留，可以继续编辑其他任务。", systemImage: "doc.text")
                                Spacer()
                                Button("继续新增") { beginAdding() }
                                Button("丢弃草稿") {
                                    if let id = retainedNewTask?.id { drafts[id] = nil }
                                    retainedNewTask = nil
                                }
                            }
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(12)
                        }
                        if store.tasks.isEmpty && newTask == nil {
                            VStack(spacing: 12) {
                                Image(systemName: "calendar.badge.plus")
                                    .font(.system(size: 32)).foregroundStyle(.secondary)
                                Text("今天由你安排").font(.title3.weight(.semibold))
                                Text("点击右上角“新增任务”，开始制定每日计划。")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 70)
                        }
                        ForEach(store.tasks.sorted { $0.startMinutes < $1.startMinutes }) { task in
                            if editingID == task.id {
                                editor(for: task, isNew: false)
                                    .id(task.id)
                            } else {
                                TaskSummaryRow(
                                    task: task,
                                    isCurrent: store.snapshot.current?.id == task.id,
                                    isCompleted: store.isTaskCompleted(task.id),
                                    hasDraft: drafts[task.id].map { $0 != TaskDraft(task: task) } ?? false,
                                    onToggleCompletion: { actionError = store.toggleTaskCompletion(id: task.id) },
                                    onEdit: { beginEditing(task) },
                                    onDelete: {
                                        actionError = store.deleteTask(id: task.id)
                                        if actionError == nil { drafts[task.id] = nil }
                                    }
                                )
                                .id(task.id)
                            }
                        }
                    }
                    .padding(22)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onChange(of: newTask?.id) { id in
                    if id != nil { proxy.scrollTo("new-task", anchor: .top) }
                }
                .onChange(of: editingID) { id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("每日重复 · 完成状态按天记录 · 编辑保存后同步悬浮窗")
                Spacer()
                Text("\(store.tasks.count) 项任务")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 520, idealHeight: 760)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("今日计划").font(.system(size: 25, weight: .bold))
                Text(store.now.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday(.wide)))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ProgressView(value: store.todayProgress.completionRate)
                        .frame(width: 92)
                    Text("已完成 \(store.todayProgress.completedCount)/\(store.todayProgress.totalCount) · \(Int(store.todayProgress.completionRate * 100))%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            Button { store.onShowHistory?() } label: { Label("历史记录", systemImage: "chart.bar") }
            Button { store.onShowSettings?() } label: { Image(systemName: "gearshape") }
                .help("设置")
            Button(action: beginAdding) { Label(retainedNewTask == nil ? "新增任务" : "继续新增", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding(22)
    }

    private func editor(for task: PlanTask, isNew: Bool) -> some View {
        TaskEditor(
            task: task,
            isNew: isNew,
            tasks: store.tasks,
            draft: Binding(
                get: { drafts[task.id] ?? TaskDraft(task: task) },
                set: { drafts[task.id] = $0 }
            ),
            onSave: { store.saveTask($0) },
            onReplace: { store.replaceTasks($0) },
            onFinish: {
                drafts[task.id] = nil
                actionError = nil
                if isNew {
                    newTask = nil
                    retainedNewTask = nil
                } else {
                    editingID = nil
                }
            },
            onCancel: {
                actionError = nil
                if isNew { newTask = nil } else { editingID = nil }
            },
            onDiscard: {
                drafts[task.id] = TaskDraft(task: task)
            }
        )
    }

    private func beginAdding() {
        editingID = nil
        if let retainedNewTask {
            newTask = retainedNewTask
        } else {
            let task = PlanEditing.draft(in: store.tasks)
            var draft = TaskDraft(task: task)
            if PlanEditing.freeSlots(in: store.tasks).isEmpty {
                draft.start = ""
                draft.end = ""
            }
            drafts[task.id] = draft
            retainedNewTask = task
            newTask = task
        }
        actionError = nil
    }

    private func beginEditing(_ task: PlanTask) {
        newTask = nil
        if drafts[task.id] == nil { drafts[task.id] = TaskDraft(task: task) }
        actionError = nil
        editingID = task.id
    }
}

private struct TaskSummaryRow: View {
    let task: PlanTask
    let isCurrent: Bool
    let isCompleted: Bool
    let hasDraft: Bool
    let onToggleCompletion: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onToggleCompletion) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isCompleted ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isCompleted ? "撤销今日完成" : "标记今日已完成")
            .accessibilityLabel("\(task.title)，\(isCompleted ? "今日已完成，点击撤销" : "标记今日完成")")
            Button(action: onEdit) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(TimeInput.format(task.startMinutes))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text(TimeInput.format(task.endMinutes))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                        if isCurrent {
                            Text("进行中")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .monospacedDigit()
                    .frame(width: 68, alignment: .leading)
                    Rectangle().fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.18))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(task.title).font(.system(size: 15, weight: .semibold))
                                .strikethrough(isCompleted)
                            if hasDraft { Text("有草稿").font(.caption2).foregroundStyle(.orange) }
                        }
                        Text(task.details.isEmpty ? "暂无详细说明" : task.details)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑\(task.title)")
            HStack(spacing: 12) {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help("在此处编辑任务").accessibilityLabel("编辑\(task.title)")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("删除任务").accessibilityLabel("删除\(task.title)")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.accentColor.opacity(0.055) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isCurrent ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }
}

private struct TaskDraft: Equatable {
    var start: String
    var end: String
    var title: String
    var details: String

    init(task: PlanTask) {
        start = TimeInput.format(task.startMinutes)
        end = task.endMinutes == 1_440 ? "24:00" : TimeInput.format(task.endMinutes)
        title = task.title
        details = task.details
    }

    func task(id: UUID) -> PlanTask? {
        guard let startMinutes = TimeInput.parse(start), startMinutes < 1_440,
              let endMinutes = TimeInput.endMinutes(from: end, startMinutes: startMinutes),
              endMinutes > startMinutes else { return nil }
        return PlanTask(id: id, startMinutes: startMinutes, endMinutes: endMinutes,
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        details: details.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private struct TaskEditor: View {
    let task: PlanTask
    let isNew: Bool
    let tasks: [PlanTask]
    @Binding var draft: TaskDraft
    let onSave: (PlanTask) -> String?
    let onReplace: ([PlanTask]) -> String?
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onDiscard: () -> Void
    @State private var error: String?
    @State private var showsReplacementPreview = false

    private var editedTask: PlanTask? { draft.task(id: task.id) }
    private var conflicts: [PlanTask] {
        editedTask.map { PlanEditing.conflicts(for: $0, in: tasks) } ?? []
    }
    private var freeSlots: [PlanTimeSlot] { PlanEditing.freeSlots(in: tasks, excluding: task.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(isNew ? "新增任务" : "编辑任务", systemImage: isNew ? "plus.circle" : "pencil.circle")
                    .font(.headline).foregroundStyle(Color.accentColor)
                Spacer()
                Text("在当前列表内编辑").font(.caption).foregroundStyle(.secondary)
            }
            if isNew && freeSlots.isEmpty {
                Label("今日已排满。可取消后调整现有任务，或指定时间并预览替换。", systemImage: "calendar.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("开始时间").font(.caption).foregroundStyle(.secondary)
                    TextField("08:00", text: $draft.start)
                        .monospacedDigit().frame(width: 94)
                        .accessibilityLabel("开始时间，24小时制")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("结束时间").font(.caption).foregroundStyle(.secondary)
                    TextField("09:00", text: $draft.end)
                        .monospacedDigit().frame(width: 94)
                        .accessibilityLabel("结束时间，24小时制")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("任务名称").font(.caption).foregroundStyle(.secondary)
                    TextField("要做些什么？", text: $draft.title)
                        .accessibilityLabel("任务名称")
                }
            }
            .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 7) {
                Text("详细说明").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.details)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 74, maxHeight: 130)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                    .accessibilityLabel("详细说明")
            }
            Text("使用 HH:mm（24 小时制）。结束时间 00:00 或 24:00 表示当天结束；结束时间需晚于开始时间。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !conflicts.isEmpty { conflictNotice }
            if !freeSlots.isEmpty && (isNew || !conflicts.isEmpty) { slotSuggestions }
            if showsReplacementPreview, let editedTask { replacementPreview(for: editedTask) }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("切换任务或取消会保留草稿，不修改已保存计划。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !isNew && draft != TaskDraft(task: task) {
                    Button("放弃修改", action: onDiscard)
                }
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("完成并保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .onSubmit(save)
        .onChange(of: draft) { _ in
            error = nil
            showsReplacementPreview = false
        }
        .onChange(of: tasks) { _ in showsReplacementPreview = false }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.55)))
    }

    private var conflictNotice: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("时间冲突：以下任务已占用这个时间段", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            ForEach(conflicts) { conflict in
                Text("\(range(of: conflict))  \(conflict.title)")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !showsReplacementPreview {
                Button("替换这个时间段…") { prepareReplacement() }
                    .help("先查看原任务如何保留或移除，确认后才保存")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var slotSuggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("可用空档（点击采用，最多填入原时长）：")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(freeSlots.prefix(3))) { slot in
                    Button(slot.displayRange) { adopt(slot) }
                        .font(.caption).monospacedDigit()
                }
                if freeSlots.count > 3 {
                    Menu("另 \(freeSlots.count - 3) 个") {
                        ForEach(Array(freeSlots.dropFirst(3))) { slot in
                            Button(slot.displayRange) { adopt(slot) }
                        }
                    }.fixedSize()
                }
            }
        }
    }

    private func replacementPreview(for edited: PlanTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("调整预览 · 尚未保存", systemImage: "list.bullet.rectangle")
                .font(.headline)
            Text("保存：\(range(of: edited))  \(edited.title)")
                .font(.callout.weight(.semibold))
            ForEach(conflicts) { original in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(original.title)（原 \(range(of: original))）")
                        .font(.callout.weight(.medium))
                    Text(replacementDescription(original, replacing: edited))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("原任务未重叠的内容会保留；完整覆盖的任务将移除。移除不能在应用内撤销。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("返回调整时间") { showsReplacementPreview = false }
                Spacer()
                Button("确认替换并保存", role: .destructive, action: confirmReplacement)
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func replacementDescription(_ original: PlanTask, replacing edited: PlanTask) -> String {
        var kept: [String] = []
        if original.startMinutes < edited.startMinutes {
            kept.append(PlanTimeSlot(startMinutes: original.startMinutes, endMinutes: edited.startMinutes).displayRange)
        }
        if original.endMinutes > edited.endMinutes {
            kept.append(PlanTimeSlot(startMinutes: edited.endMinutes, endMinutes: original.endMinutes).displayRange)
        }
        return kept.isEmpty ? "完整覆盖，将移除此任务。" : "保留 \(kept.joined(separator: " 和 "))，名称与详细说明保留。"
    }

    private func range(of task: PlanTask) -> String {
        PlanTimeSlot(startMinutes: task.startMinutes, endMinutes: task.endMinutes).displayRange
    }

    private func adopt(_ slot: PlanTimeSlot) {
        let duration = editedTask.map { $0.endMinutes - $0.startMinutes } ?? 30
        draft.start = TimeInput.format(slot.startMinutes)
        let adoptedEnd = min(slot.startMinutes + duration, slot.endMinutes)
        draft.end = adoptedEnd == 1_440 ? "24:00" : TimeInput.format(adoptedEnd)
    }

    private func validatedTask() -> PlanTask? {
        guard let start = TimeInput.parse(draft.start), start < 1_440 else {
            error = "开始时间格式有误，请使用 00:00～23:59。"
            return nil
        }
        guard let end = TimeInput.endMinutes(from: draft.end, startMinutes: start) else {
            error = "结束时间格式有误，请使用 HH:mm（例如 09:50）。"
            return nil
        }
        let edited = PlanTask(id: task.id, startMinutes: start, endMinutes: end,
                              title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                              details: draft.details.trimmingCharacters(in: .whitespacesAndNewlines))
        if let reason = PlanValidator.validate([edited]) {
            error = reason
            return nil
        }
        return edited
    }

    private func save() {
        guard let edited = validatedTask() else { return }
        if !PlanEditing.conflicts(for: edited, in: tasks).isEmpty {
            error = "请选择可用空档、调整时间，或点击“替换这个时间段…”查看调整预览。"
            return
        }
        if let message = onSave(edited) { error = message } else { onFinish() }
    }

    private func prepareReplacement() {
        guard validatedTask() != nil else { return }
        error = nil
        showsReplacementPreview = true
    }

    private func confirmReplacement() {
        guard let edited = validatedTask() else { return }
        do {
            let candidate = try PlanEditing.replacingConflicts(with: edited, in: tasks)
            if let message = onReplace(candidate) { error = message } else { onFinish() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
