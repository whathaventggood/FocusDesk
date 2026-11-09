import AppKit
import SwiftUI

struct CompactView: View {
    @ObservedObject var store: PlanStore
    let onHover: (Bool) -> Void
    let onResize: (CGFloat) -> Void

    private var session: ActivityTimerSession? { store.activityTimers.displayedSession }
    private var isDue: Bool { session?.isAwaitingCompletion == true }
    private var accent: Color { isDue ? store.theme.finished : store.theme.accent }
    private var progress: Double { session.map { $0.progress(at: store.activityDisplayNow) } ?? store.snapshot.progress }
    private var side: CGFloat { CGFloat(store.compactSize) }
    private var activityName: String {
        store.activityTimers.activities.first { $0.id == session?.activityID }?.name ?? L("事项")
    }
    private var clock: String {
        guard let session else { return "" }
        let value = session.mode == .countdown ? session.remaining(at: store.activityDisplayNow) : session.elapsed(at: store.activityDisplayNow)
        let formatted = ActivityDurationFormat.clock(value, roundUp: session.mode == .countdown)
        return value < 3600 ? String(formatted.dropFirst(3)) : formatted
    }

    var body: some View {
        ClockDrivenContent(clock: store.clock, enabled: true) { content }
    }

    private var content: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .fill(store.theme.background)
            ThemeTexture(theme: store.theme)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.24))
            if isDue {
                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    .fill(accent.opacity(0.08))
            }
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .strokeBorder(accent.opacity(store.isExpanded ? 0.55 : 0.18), lineWidth: 1)
            Circle()
                .stroke(accent.opacity(0.13), lineWidth: max(2, side * 0.05))
                .frame(width: side * 0.66, height: side * 0.66)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: max(2, side * 0.05), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: side * 0.66, height: side * 0.66)
            if session != nil {
                VStack(spacing: side * 0.035) {
                    if isDue {
                        Text(L("已到时"))
                            .font(.system(size: side * 0.17, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else if side >= 48 {
                        Text(clock)
                            .font(.system(size: side * (clock.count > 5 ? 0.12 : 0.17), weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        Image(systemName: session?.isPaused == true ? "pause" : "timer")
                            .font(.system(size: side * 0.24, weight: .medium))
                    }
                    if side >= 48 {
                        Text(session?.isPaused == true ? L("已暂停") : activityName)
                            .font(.system(size: side * 0.12, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .frame(width: side * 0.56)
                .foregroundStyle(accent)
            } else {
                Image(systemName: store.theme.symbol)
                    .font(.system(size: side * 0.29, weight: .medium))
                    .foregroundStyle(accent)
            }

            if store.errorMessage != nil || store.activityTimerError != nil {
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
                .accessibilityLabel(L("拖动调整小方块大小"))
                .accessibilityValue(L("%@ 点", "\(Int(side))"))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onResize(side + 4)
                    case .decrement: onResize(side - 4)
                    @unknown default: break
                    }
                }
        }
        .onHover(perform: onHover)
        .fontDesign(store.theme.design)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("FocusDesk 小方块，悬停查看任务，拖动空白区域移动"))
        .accessibilityValue(session == nil ? (store.snapshot.current?.title ?? L("自由时间"))
                            : L("%@，%@", "\(activityName)", "\(isDue ? L("已到时") : session?.isPaused == true ? L("已暂停，%@", clock) : clock)"))
        .help(session == nil ? L("悬停查看每日任务") : L("%@ · %@", "\(activityName)", "\(isDue ? L("已到时 · 可继续专注") : clock)"))
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
    static let panelSize = NSSize(width: 360, height: 580)

    @ObservedObject var store: PlanStore
    @State private var completionError: String?

    private var accent: Color { store.theme.accent }

    var body: some View {
        ClockDrivenContent(clock: store.clock, enabled: true) { content }
    }

    private var content: some View {
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
                    .help(L("计划存储有提示，点击查看"))
                    .accessibilityLabel(L("查看计划存储提示"))
                }
                Button { store.onShowSettings?() } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("设置"))
                .accessibilityLabel(L("打开设置"))
            }

            if let session = store.activityTimers.displayedSession {
                FloatingActivityTimer(store: store, session: session)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Circle().fill(accent).frame(width: 6, height: 6)
                        Text(store.snapshot.current == nil ? L("自由时间") : L("正在进行"))
                        Spacer()
                        Text(intervalLabel)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                    Text(store.snapshot.current?.title ?? L("自由时间"))
                        .font(.system(size: 23, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(store.snapshot.current?.details ?? L("放松一下，按照自己的节奏安排这段时间。"))
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
                        Text(store.snapshot.next == nil && store.snapshot.current == nil ? L("今日剩余") : L("剩余"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(store.snapshot.progress * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: store.snapshot.progress)
                        .tint(accent)
                        .accessibilityLabel(L("当前时间段进度"))
                }

                Divider()

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(nextTimeLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(store.snapshot.next?.title ?? L("今天由你安排"))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Button(L("今日计划")) { store.onShowPlan?() }
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
                            Label(done ? L("已完成") : L("标记完成"), systemImage: done ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(done ? Color.green : accent)
                    }
                    Spacer(minLength: 2)
                    Text(L("今日 %@/%@", "\(store.todayProgress.completedCount)", "\(store.todayProgress.totalCount)"))
                        .foregroundStyle(.secondary)
                    Button { store.onShowHistory?() } label: { Image(systemName: "chart.bar.xaxis") }
                        .buttonStyle(.plain)
                        .help(L("计划回顾"))
                        .accessibilityLabel(L("打开专注记录"))
                }
                .font(.system(size: 11))
            }

            if store.activityTimers.displayedSession == nil {
                ActivityTimerStrip(store: store)
            } else {
                HStack {
                    Text(L("今日计划 %@/%@", "\(store.todayProgress.completedCount)", "\(store.todayProgress.totalCount)"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("今日计划")) { store.onShowPlan?() }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                }
                .font(.system(size: 11))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(store.motivationalQuote.text)
                    .font(.system(size: 13, weight: .medium))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("motivationalQuote")

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        store.onShowQuoteDetails?(store.motivationalQuote)
                    } label: {
                        HStack(spacing: 3) {
                            Text(L("解释与出处"))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("查看这句话的解释与出处"))
                    .accessibilityIdentifier("quoteDetailsButton")
                    .accessibilityLabel(L("查看励志语句的解释与出处"))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
        }
        .padding(22)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        .modifier(ThemeSurface(store: store, themedTypography: true))
        .id(store.language)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
        .alert(L("完成状态未保存"), isPresented: Binding(
            get: { completionError != nil },
            set: { if !$0 { completionError = nil } }
        )) {
            Button(L("好")) { completionError = nil }
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
        guard let date = store.snapshot.nextStart else { return L("下一项 · 暂无任务") }
        let day = Calendar.current.isDate(date, inSameDayAs: store.now) ? "" : L("明天 ")
        return L("下一项 · %@%@", "\(day)", "\(clockString(date))")
    }

    private func clockString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

enum ActivityTimerAppearance {
    static let accent = Color(red: 0.28, green: 0.40, blue: 0.87)
    static let finished = Color(red: 0.64, green: 0.48, blue: 0.28)
}

/// The desktop details and the timer window share the same persisted session.
private struct FloatingActivityTimer: View {
    @ObservedObject var store: PlanStore
    let session: ActivityTimerSession

    private var isDue: Bool { session.isAwaitingCompletion }
    private var accent: Color { isDue ? store.theme.finished : store.theme.accent }
    private var name: String {
        store.activityTimers.activities.first { $0.id == session.activityID }?.name ?? L("事项")
    }

    var body: some View {
        ClockDrivenContent(clock: store.clock, enabled: session.runningSince != nil) { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label(isDue ? L("已到时") : session.isPaused ? L("已暂停") : L("事项%@", "\(session.mode.title)"),
                      systemImage: isDue ? "checkmark.circle" : session.isPaused ? "pause.circle" : "timer")
                Spacer()
                Button(L("事项计时")) { store.onShowTimers?() }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(accent)

            Text(name)
                .font(.system(size: 23, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("floatingActivityName")

            Text(isDue ? L("这段专注已记录，按自己的节奏收尾。") : session.isPaused ? L("休息一下，准备好后继续。") : L("专注于当前事项，让时间安静地流动。"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text(isDue ? L("已到时") : ActivityDurationFormat.clock(
                    session.mode == .countdown ? session.remaining(at: store.activityDisplayNow) : session.elapsed(at: store.activityDisplayNow),
                    roundUp: session.mode == .countdown))
                    .font(.system(size: isDue ? 30 : 38, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isDue ? accent : .primary)
                    .accessibilityIdentifier("floatingActivityClock")
                Text(isDue ? L("可继续专注") : session.mode == .countdown ? L("剩余时间") : L("已用时"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if session.mode == .countdown {
                    ProgressView(value: session.progress(at: store.activityDisplayNow))
                        .tint(accent)
                        .accessibilityLabel(L("事项倒计时进度"))
                }
            }
            .padding(.vertical, 8)

            HStack {
                if isDue {
                    Button(L("+5 分钟")) { Task { await store.performActivityAction(.extend) } }
                        .help(L("从现在开始，为这个事项再计时 5 分钟"))
                        .accessibilityIdentifier("floatingExtendCountdown")
                } else {
                    Button(session.isPaused ? L("继续") : L("暂停")) { Task { await store.performActivityAction(.togglePause) } }
                }
                Spacer()
                Button(isDue ? L("完成") : L("结束并记录")) { Task { await store.performActivityAction(.finish) } }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .accessibilityIdentifier("floatingFinishTimer")
            }
            .controlSize(.small)
            .disabled(store.activityIsBusy)

            if let error = store.activityTimerError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floatingActivityTimer")
    }
}

/// The quote is captured when opened, so an hourly refresh cannot change what is being read.
struct QuoteDetailView: View {
    let quote: MotivationalQuote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(quote.text)
                    .font(.system(size: 21, weight: .medium))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quoteDetailText")

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("解释"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(quote.explanation)
                        .accessibilityIdentifier("quoteExplanation")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("出处"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(quote.source)
                        .accessibilityIdentifier("quoteSource")
                }
            }
            .font(.system(size: 14))
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
