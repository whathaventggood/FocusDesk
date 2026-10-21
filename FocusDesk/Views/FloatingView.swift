import SwiftUI

struct FloatingView: View {
    @ObservedObject var store: PlanStore

    private let accent = Color(red: 0.28, green: 0.40, blue: 0.87)

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(accent)
                Text("FocusDesk")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(store.now, style: .time)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                if store.errorMessage != nil {
                    Button { store.onShowPlan?() } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("计划存储有提示，点击查看")
                    .accessibilityLabel("查看计划存储提示")
                }
                Button { store.onShowSettings?() } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("设置")
                .accessibilityLabel("打开设置")
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(store.snapshot.current == nil ? "自由时间" : "正在进行")
                    Spacer()
                    Text(intervalLabel)
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                Text(store.snapshot.current?.title ?? "自由时间")
                    .font(.system(size: 23, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(store.snapshot.current?.details ?? "放松一下，按照自己的节奏安排这段时间。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.disabled)
                }
                .frame(height: 58)
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(remainingLabel)
                        .font(.system(size: 30, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text(store.snapshot.next == nil && store.snapshot.current == nil ? "今日剩余" : "剩余")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(store.snapshot.progress * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: store.snapshot.progress)
                    .tint(accent)
                    .accessibilityLabel("当前时间段进度")
            }

            Divider()

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(nextTimeLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(store.snapshot.next?.title ?? "今天由你安排")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Button("今日计划") { store.onShowPlan?() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
            }
        }
        .padding(22)
        .frame(width: 360, height: 400, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
    }

    private var intervalLabel: String {
        if let task = store.snapshot.current {
            return "\(TimeInput.format(task.startMinutes)) – \(TimeInput.format(task.endMinutes))"
        }
        return "\(clockString(store.snapshot.intervalStart)) – \(clockString(store.snapshot.intervalEnd))"
    }

    private var remainingLabel: String {
        let seconds = max(0, Int(ceil(store.snapshot.remaining)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private var nextTimeLabel: String {
        guard let date = store.snapshot.nextStart else { return "下一项 · 暂无任务" }
        let day = Calendar.current.isDate(date, inSameDayAs: store.now) ? "" : "明天 "
        return "下一项 · \(day)\(clockString(date))"
    }

    private func clockString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
