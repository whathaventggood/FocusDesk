import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: PlanStore
    @State private var range = 7
    @State private var expandedDay: String?

    private var records: [DailyProgress] {
        let today = store.todayProgress.day
        guard range > 0 else { return store.history.filter { $0.day <= today } }
        let cutoff = Calendar.current.date(byAdding: .day, value: -(range - 1), to: store.now) ?? store.now
        let earliest = dayKey(cutoff)
        return store.history.filter { earliest <= $0.day && $0.day <= today }
    }

    private var completed: Int { records.reduce(0) { $0 + $1.completedCount } }
    private var total: Int { records.reduce(0) { $0 + $1.totalCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("专注记录").font(.system(size: 25, weight: .bold))
                    Text("回顾每天的计划与完成情况")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("事项时长") { store.onShowTimers?() }
                Button("今日计划") { store.onShowPlan?() }
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("统计范围", selection: $range) {
                        Text("近 7 天").tag(7)
                        Text("近 30 天").tag(30)
                        Text("全部").tag(0)
                    }
                    .pickerStyle(.segmented)
                    if let message = store.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 14) {
                        ProgressStat(title: "完成率", value: total == 0 ? "—" : "\(Int((Double(completed) / Double(total) * 100).rounded()))%")
                        ProgressStat(title: "已完成任务", value: "\(completed) / \(total)")
                        ProgressStat(title: "记录天数", value: "\(records.count) 天")
                    }
                    Text("完成率 = 手动标记完成的任务数 ÷ 计划任务数，包含休息等全部任务。仅统计有记录的日期；未运行的日期不补记，时间结束不会自动完成。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !records.isEmpty {
                        VStack(alignment: .leading, spacing: 11) {
                            Text("每日完成率").font(.headline)
                            ForEach(Array(records.prefix(14).reversed())) { record in
                                HStack(spacing: 12) {
                                    Text(record.day).font(.system(size: 11, design: .monospaced))
                                        .frame(width: 88, alignment: .leading)
                                    ProgressView(value: record.completionRate)
                                        .tint(.accentColor)
                                    Text(record.totalCount == 0 ? "无任务" : "\(Int((record.completionRate * 100).rounded()))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                        .padding(18)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(records) { record in
                        DailyHistoryCard(
                            record: record,
                            isToday: record.day == store.todayProgress.day,
                            isExpanded: Binding(
                                get: { expandedDay == record.day },
                                set: { expandedDay = $0 ? record.day : nil }
                            )
                        )
                    }
                    if records.isEmpty {
                        Text("这个时间范围还没有记录。完成今日任务后，在计划列表中勾选即可。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 50)
                    }
                }
                .padding(24)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 650, idealWidth: 800, minHeight: 520, idealHeight: 720)
        .onAppear { if expandedDay == nil { expandedDay = store.todayProgress.day } }
        .onChange(of: store.todayProgress.day) { expandedDay = $0 }
    }

    private func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private struct ProgressStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DailyHistoryCard: View {
    let record: DailyProgress
    let isToday: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                Text("记录时区：\(record.timeZoneIdentifier)")
                    .font(.caption).foregroundStyle(.secondary)
                if record.tasks.isEmpty {
                    Text("当天没有安排任务").foregroundStyle(.secondary)
                }
                ForEach(record.tasks) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.completedAt == nil ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(item.completedAt == nil ? Color.secondary : .green)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.task.title).font(.callout.weight(.medium))
                            Text("\(TimeInput.format(item.task.startMinutes))–\(TimeInput.format(item.task.endMinutes)) · \(item.completedAt == nil ? "未完成" : "已完成")")
                                .font(.caption).foregroundStyle(.secondary)
                            if !item.task.details.isEmpty {
                                Text(item.task.details).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(.top, 14)
        } label: {
            HStack {
                Text(record.day + (isToday ? " · 今天" : "")).font(.headline)
                Spacer()
                Text("\(record.completedCount) / \(record.totalCount) 已完成")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
