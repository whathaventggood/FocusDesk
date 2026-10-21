import SwiftUI

struct PlanView: View {
    @ObservedObject var store: PlanStore
    @State private var editingID: UUID?
    @State private var newTask: PlanTask?
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
                            TaskEditor(task: task, isNew: true) { updated in
                                store.saveTask(updated)
                            } onFinish: {
                                newTask = nil
                            } onCancel: {
                                newTask = nil
                            }
                            .id("new-task")
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
                                TaskEditor(task: task, isNew: false) { updated in
                                    store.saveTask(updated)
                                } onFinish: {
                                    editingID = nil
                                } onCancel: {
                                    editingID = nil
                                }
                                .id(task.id)
                            } else {
                                TaskSummaryRow(
                                    task: task,
                                    isCurrent: store.snapshot.current?.id == task.id,
                                    onEdit: { beginEditing(task) },
                                    onDelete: { actionError = store.deleteTask(id: task.id) }
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
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("每日重复 · 完成编辑后立即保存并同步悬浮窗")
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
            }
            Spacer()
            Button { store.onShowSettings?() } label: { Image(systemName: "gearshape") }
                .help("设置")
            Button {
                if editingID != nil || newTask != nil {
                    actionError = "请先保存或取消当前编辑，再新增任务。"
                    return
                }
                newTask = makeNewTask()
                actionError = nil
            } label: { Label("新增任务", systemImage: "plus") }
            .buttonStyle(.borderedProminent)
        }
        .padding(22)
    }

    private func beginEditing(_ task: PlanTask) {
        guard newTask == nil, editingID == nil else {
            actionError = "请先保存或取消当前编辑，再编辑其他任务。"
            return
        }
        actionError = nil
        editingID = task.id
    }

    private func makeNewTask() -> PlanTask {
        var cursor = 0
        for task in store.tasks.sorted(by: { $0.startMinutes < $1.startMinutes }) {
            if task.startMinutes > cursor {
                return PlanTask(startMinutes: cursor, endMinutes: min(cursor + 30, task.startMinutes), title: "", details: "")
            }
            cursor = max(cursor, task.endMinutes)
        }
        if cursor < 1440 {
            return PlanTask(startMinutes: cursor, endMinutes: min(cursor + 30, 1440), title: "", details: "")
        }
        return PlanTask(startMinutes: 540, endMinutes: 570, title: "", details: "")
    }
}

private struct TaskSummaryRow: View {
    let task: PlanTask
    let isCurrent: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
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
                Text(task.title).font(.system(size: 15, weight: .semibold))
                Text(task.details.isEmpty ? "暂无详细说明" : task.details)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .contain)
    }
}

private struct TaskEditor: View {
    let task: PlanTask
    let isNew: Bool
    let onSave: (PlanTask) -> String?
    let onFinish: () -> Void
    let onCancel: () -> Void
    @State private var start: String
    @State private var end: String
    @State private var title: String
    @State private var details: String
    @State private var error: String?

    init(task: PlanTask, isNew: Bool, onSave: @escaping (PlanTask) -> String?, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.task = task
        self.isNew = isNew
        self.onSave = onSave
        self.onFinish = onFinish
        self.onCancel = onCancel
        _start = State(initialValue: TimeInput.format(task.startMinutes))
        _end = State(initialValue: TimeInput.format(task.endMinutes))
        _title = State(initialValue: task.title)
        _details = State(initialValue: task.details)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(isNew ? "新增任务" : "编辑任务", systemImage: isNew ? "plus.circle" : "pencil.circle")
                    .font(.headline).foregroundStyle(Color.accentColor)
                Spacer()
                Text("在当前列表内编辑").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("开始时间").font(.caption).foregroundStyle(.secondary)
                    TextField("08:00", text: $start)
                        .monospacedDigit().frame(width: 94)
                        .accessibilityLabel("开始时间，24小时制")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("结束时间").font(.caption).foregroundStyle(.secondary)
                    TextField("09:00", text: $end)
                        .monospacedDigit().frame(width: 94)
                        .accessibilityLabel("结束时间，24小时制")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("任务名称").font(.caption).foregroundStyle(.secondary)
                    TextField("要做些什么？", text: $title)
                        .accessibilityLabel("任务名称")
                }
            }
            .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 7) {
                Text("详细说明").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $details)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 74, maxHeight: 130)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                    .accessibilityLabel("详细说明")
            }
            Text("使用 HH:mm（24 小时制）。结束时间 00:00 表示当天结束；其他结束时间需晚于开始时间。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("完成并保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .onSubmit(save)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.55)))
    }

    private func save() {
        guard let startMinutes = TimeInput.parse(start), startMinutes < 1440 else {
            error = "开始时间格式有误，请使用 00:00～23:59。"
            return
        }
        guard let endMinutes = TimeInput.endMinutes(from: end, startMinutes: startMinutes) else {
            error = "结束时间格式有误，请使用 HH:mm（例如 09:50）。"
            return
        }
        let updated = PlanTask(id: task.id, startMinutes: startMinutes, endMinutes: endMinutes,
                               title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                               details: details.trimmingCharacters(in: .whitespacesAndNewlines))
        if let message = onSave(updated) {
            error = message
        } else {
            onFinish()
        }
    }
}
