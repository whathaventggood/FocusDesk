import AppKit
import SwiftUI

struct CompactView: View {
    @ObservedObject var store: PlanStore
    let onHover: (Bool) -> Void
    let onResize: (CGFloat) -> Void

    private let accent = Color(red: 0.28, green: 0.40, blue: 0.87)
    private var side: CGFloat { CGFloat(store.compactSize) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .strokeBorder(accent.opacity(store.isExpanded ? 0.55 : 0.18), lineWidth: 1)
            Circle()
                .stroke(accent.opacity(0.13), lineWidth: max(2, side * 0.05))
                .frame(width: side * 0.66, height: side * 0.66)
            Circle()
                .trim(from: 0, to: store.snapshot.progress)
                .stroke(accent, style: StrokeStyle(lineWidth: max(2, side * 0.05), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: side * 0.66, height: side * 0.66)
            Image(systemName: "timer")
                .font(.system(size: side * 0.29, weight: .medium))
                .foregroundStyle(accent)
            if store.errorMessage != nil {
                Circle().fill(.orange)
                    .frame(width: max(5, side * 0.1), height: max(5, side * 0.1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(side * 0.11)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: max(7, side * 0.13), weight: .medium))
                .foregroundStyle(accent.opacity(0.65))
                .frame(width: max(14, side * 0.25), height: max(14, side * 0.25))
                .overlay(CompactResizeHandle(side: side, onResize: onResize))
                .padding(2)
                .accessibilityLabel("拖动调整小方块大小")
                .accessibilityValue("\(Int(side)) 点")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onResize(side + 4)
                    case .decrement: onResize(side - 4)
                    @unknown default: break
                    }
                }
        }
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("FocusDesk 小方块，悬停查看任务，拖动空白区域移动")
    }
}

/// Screen coordinates keep resizing stable while the panel's own frame changes.
private struct CompactResizeHandle: NSViewRepresentable {
    let side: CGFloat
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeHandleView {
        ResizeHandleView(side: side, onResize: onResize)
    }

    func updateNSView(_ view: ResizeHandleView, context: Context) {
        view.side = side
        view.onResize = onResize
    }

    final class ResizeHandleView: NSView {
        var side: CGFloat
        var onResize: (CGFloat) -> Void
        private var dragStart: NSPoint?
        private var initialSide: CGFloat = 0

        init(side: CGFloat, onResize: @escaping (CGFloat) -> Void) {
            self.side = side
            self.onResize = onResize
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            dragStart = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            initialSide = side
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            let position = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            let widthChange = position.x - dragStart.x
            let heightChange = dragStart.y - position.y
            let change = abs(widthChange) > abs(heightChange) ? widthChange : heightChange
            onResize(initialSide + change)
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
        }
    }
}

struct FloatingView: View {
    @ObservedObject var store: PlanStore
    @State private var completionError: String?

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

            HStack(spacing: 8) {
                if let task = store.snapshot.current {
                    let done = store.isTaskCompleted(task.id)
                    Button {
                        completionError = store.toggleTaskCompletion(id: task.id)
                    } label: {
                        Label(done ? "已完成" : "标记完成", systemImage: done ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(done ? Color.green : accent)
                }
                Spacer(minLength: 2)
                Text("今日 \(store.todayProgress.completedCount)/\(store.todayProgress.totalCount)")
                    .foregroundStyle(.secondary)
                Button { store.onShowHistory?() } label: { Image(systemName: "chart.bar.xaxis") }
                    .buttonStyle(.plain)
                    .help("专注记录")
                    .accessibilityLabel("打开专注记录")
            }
            .font(.system(size: 11))
        }
        .padding(22)
        .frame(width: 360, height: 400, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
        .alert("完成状态未保存", isPresented: Binding(
            get: { completionError != nil },
            set: { if !$0 { completionError = nil } }
        )) {
            Button("好") { completionError = nil }
        } message: {
            Text(completionError ?? "")
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
