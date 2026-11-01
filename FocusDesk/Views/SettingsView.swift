import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: PlanStore
    @State private var confirmRecovery = false
    @State private var recoveryError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 30)).foregroundStyle(store.theme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("FocusDesk 设置")).font(.title2.weight(.semibold))
                        Text(L("让计划安静地陪你完成每一天"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Picker("Language / 语言", selection: $store.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                GroupBox(L("外观与到时特效")) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(L("主题"))
                            Menu {
                                ForEach(DeskTheme.allCases) { theme in
                                    Button(theme.title) { store.theme = theme }
                                }
                            } label: {
                                Text(store.theme.title).foregroundStyle(store.theme.foreground)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .padding(8)
                            .background(store.theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                        HStack(spacing: 12) {
                            Image(systemName: store.theme.symbol)
                                .font(.title).foregroundStyle(store.theme.accent)
                            VStack(alignment: .leading) {
                                Text(store.theme.title).font(.headline)
                                Text(L("25:00 · 按自己的节奏专注")).monospacedDigit()
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(store.theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        Toggle(L("启用到时特效"), isOn: $store.effectsEnabled)
                        HStack {
                            Text(L("特效"))
                            Menu {
                                ForEach(CountdownEffect.allCases) { effect in
                                    Button(effect.title) { store.countdownEffect = effect }
                                }
                            } label: {
                                Text(store.countdownEffect.title).foregroundStyle(store.theme.foreground)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .padding(8)
                            .background(store.theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                        Picker(L("强度"), selection: $store.effectIntensity) {
                            ForEach(EffectIntensity.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Button(L("预览桌面特效")) { store.onPreviewEffect?() }
                            .disabled(!store.effectsEnabled)
                        Text(L("特效只在到时或点击预览时播放，持续约 2–4 秒。系统开启“减少动态效果”时保留静态提醒。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(L("桌面小方块大小"))
                                Spacer()
                                Text("\(Int(store.compactSize)) × \(Int(store.compactSize))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $store.compactSize, in: PlanStore.compactSizeRange, step: 1)
                                .accessibilityLabel(L("桌面小方块大小"))
                            HStack {
                                Text(L("32 点"))
                                Spacer()
                                Button(L("恢复默认")) { store.compactSize = PlanStore.defaultCompactSize }
                                    .buttonStyle(.link)
                                Spacer()
                                Text(L("112 点"))
                            }
                            .font(.caption)
                        }
                        Text(L("鼠标移入小方块展开任务，移出小方块与任务窗后自动收起。拖动方块移动位置，拖动右下角调整大小。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle(L("小方块与悬浮窗始终置顶"), isOn: $store.alwaysOnTop)
                        Text(L("开启后显示在其他应用窗口上方。关闭后仍会保留在桌面，可通过菜单栏找回。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle(L("登录 macOS 时启动"), isOn: Binding(
                            get: { store.launchAtLogin },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                        Text(store.launchAtLoginStatus)
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L("打开系统登录项设置")) {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .controlSize(.small)
                    }
                    .padding(12)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("计划与设置仅保存在本机"), systemImage: "internaldrive")
                        .font(.callout.weight(.medium))
                    Text(L("计划按每天的系统本地时间重复。小方块的位置和大小会自动保存，睡眠唤醒后会自动校准当前任务。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = store.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.needsDataRecovery {
                    Button(L("备份原文件并恢复默认计划…"), role: .destructive) {
                        confirmRecovery = true
                    }
                    Text(L("恢复会重置当前计划和完成记录；损坏的原文件会先备份到本机，不会静默覆盖。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let recoveryError {
                    Text(recoveryError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text(L("FocusDesk %@", "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版")"))
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button(L("专注记录")) { store.onShowHistory?() }
                    Button(L("今日计划")) { store.onShowPlan?() }
                }
            }
            .padding(28)
        }
        .frame(width: 520, height: 720)
        .modifier(ThemeSurface(store: store))
        .id(store.language)
        .confirmationDialog(L("恢复默认计划并重置完成记录？"), isPresented: $confirmRecovery) {
            Button(L("确认备份并恢复"), role: .destructive) {
                recoveryError = store.recoverWithDefaultPlan()
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("原文件备份成功后才会恢复。历史完成记录将重置，保留的备份可用于后续恢复。"))
        }
    }
}

// Palettes are shared by desktop and management windows; preferences contain only stable IDs.
enum DeskTheme: String, CaseIterable, Identifiable {
    case classic, vintage, terminal, minimal, blueprint, cyber, gentle, forest, horror, pixel, moon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return L("经典蓝")
        case .vintage: return L("纸上时光 · 复古")
        case .terminal: return L("深空终端 · 科技")
        case .minimal: return L("留白 · 极简")
        case .blueprint: return L("工程蓝图 · 理工科")
        case .cyber: return L("霓虹夜航 · 赛博")
        case .gentle: return L("奶油日光 · 温柔")
        case .forest: return L("林间薄雾 · 自然")
        case .horror: return L("午夜档案 · 微恐怖")
        case .pixel: return L("掌上像素 · 复古游戏")
        case .moon: return L("月下银幕 · 沉静")
        }
    }
    var dark: Bool { [.terminal, .blueprint, .cyber, .horror, .pixel, .moon].contains(self) }
    var accent: Color {
        Color(hex: ["classic":0x4766DE, "vintage":0x875737, "terminal":0x52D5ED,
                    "minimal":0x55565B, "blueprint":0x87CCFF, "cyber":0xD291FF,
                    "gentle":0x9A7259, "forest":0x49715C, "horror":0xDE7275,
                    "pixel":0xB4E077, "moon":0xB8B7E6][rawValue]!)
    }
    var background: Color {
        Color(hex: ["classic":0xF3F4F8, "vintage":0xF2E6CF, "terminal":0x0C1B29,
                    "minimal":0xF7F7F7, "blueprint":0x16344F, "cyber":0x1D122C,
                    "gentle":0xFBF0E4, "forest":0xE7EEE5, "horror":0x211C20,
                    "pixel":0x1D2924, "moon":0x242630][rawValue]!)
    }
    var foreground: Color { dark ? Color(hex: 0xEEEFF3) : Color(hex: 0x292A30) }
    var finished: Color { dark ? accent : Color(hex: self == .forest ? 0x4B735B : 0x9B693E) }
    var design: Font.Design {
        if [.terminal, .blueprint, .cyber, .pixel].contains(self) { return .monospaced }
        if [.vintage, .horror].contains(self) { return .serif }
        return self == .gentle ? .rounded : .default
    }
    var symbol: String {
        switch self {
        case .vintage: return "clock"
        case .terminal, .cyber: return "cpu"
        case .blueprint: return "scope"
        case .gentle: return "sun.max"
        case .forest: return "leaf"
        case .horror: return "eye"
        case .pixel: return "flag.checkered"
        case .moon: return "moon"
        default: return "timer"
        }
    }
}

enum CountdownEffect: String, CaseIterable, Identifiable {
    case soft, glitch, energy, blackhole, hologram, ice, mechanical, shadow, petals, pixels
    var id: String { rawValue }
    var title: String {
        switch self {
        case .soft: return L("柔和光晕")
        case .glitch: return L("赛博故障")
        case .energy: return L("能量爆发")
        case .blackhole: return L("黑洞坍缩")
        case .hologram: return L("全息解构")
        case .ice: return L("冰封碎裂")
        case .mechanical: return L("机械仪表")
        case .shadow: return L("幽影侵蚀")
        case .petals: return L("花开与流萤")
        case .pixels: return L("像素通关")
        }
    }
}

enum EffectIntensity: String, CaseIterable, Identifiable {
    case gentle, standard, dramatic
    var id: String { rawValue }
    var title: String { self == .gentle ? L("轻柔") : self == .standard ? L("标准") : L("夸张") }
    var duration: Double { self == .gentle ? 1.8 : self == .standard ? 2.8 : 4 }
    var amount: Double { self == .gentle ? 0.5 : self == .standard ? 0.75 : 1 }
}

extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct ThemeSurface: ViewModifier {
    @ObservedObject var store: PlanStore
    func body(content: Content) -> some View {
        content
            .environment(\.locale, Locale(identifier: store.language.rawValue))
            .fontDesign(store.theme.design)
            .tint(store.theme.accent)
            .foregroundStyle(store.theme.foreground)
            .background {
                store.theme.background
                ThemeTexture(theme: store.theme)
            }
            .preferredColorScheme(store.theme == .classic || store.theme == .minimal ? nil : store.theme.dark ? .dark : .light)
    }
}

/// Deterministic particles keep every frame stable. A single timeline is removed after playback.
struct CountdownEffectView: View {
    let theme: DeskTheme
    let effect: CountdownEffect
    let intensity: EffectIntensity
    let startedAt: Date
    var body: some View {
        TimelineView(.animation) { timeline in
            let progress = min(1, max(0, timeline.date.timeIntervalSince(startedAt) / intensity.duration))
            Canvas { context, size in
                Self.draw(context: &context, size: size, theme: theme, effect: effect,
                          progress: progress, amount: intensity.amount)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func draw(context: inout GraphicsContext, size: CGSize, theme: DeskTheme,
                     effect: CountdownEffect, progress p: Double, amount: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.43 * amount
        let fade = sin(p * .pi)
        guard p > 0, p < 1 else { return }
        let color = theme.accent
        func point(_ angle: Double, _ distance: Double) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
        }
        func circle(_ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: 2*r, height: 2*r))
        }
        switch effect {
        case .soft, .energy:
            for ring in 0..<(effect == .soft ? 1 : 3) {
                let t = max(0, p - Double(ring) * 0.13)
                context.stroke(circle(18 + radius * t), with: .color(color.opacity(fade * (1-t))), lineWidth: effect == .soft ? 2 : 4 - Double(ring))
            }
        case .blackhole:
            context.fill(circle(18 + 28 * fade), with: .color(.black.opacity(fade * 0.85)))
            for arm in 0..<5 {
                var path = Path()
                for step in 0..<70 {
                    let t = Double(step) / 69
                    let pt = point(t * 5 + p * 8 + Double(arm) * 1.256, 14 + radius * t * (1-p))
                    if step == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                context.stroke(path, with: .color(color.opacity(fade)), lineWidth: 2)
            }
        case .mechanical:
            for ring in 0..<3 {
                let r = 25 + Double(ring) * radius * 0.25
                context.stroke(circle(r), with: .color(color.opacity(fade * 0.5)), lineWidth: 1)
                for tick in 0..<24 {
                    let a = Double(tick) * .pi / 12 + p * (ring % 2 == 0 ? 2 : -2)
                    var path = Path(); path.move(to: point(a, r)); path.addLine(to: point(a, r + (tick % 3 == 0 ? 9 : 4)))
                    context.stroke(path, with: .color(color.opacity(fade)), lineWidth: 2)
                }
            }
        case .glitch:
            for index in 0..<12 {
                let shift = sin(p * 18 + Double(index) * 3) * 25 * amount
                let rect = CGRect(x: center.x - radius * 0.7 + shift, y: center.y - 55 + Double(index) * 10, width: radius * 1.4, height: index % 3 == 0 ? 5 : 1)
                context.fill(Path(rect), with: .color((index % 2 == 0 ? Color.cyan : Color.pink).opacity(fade * 0.7)))
            }
        default: break
        }
        let count = Int(48 * amount)
        for index in 0..<count {
            let seed = Double(index)
            let angle = seed * 2.39996
            let t = (seed.truncatingRemainder(dividingBy: 7) + 1) / 8
            let distance = 22 + radius * (effect == .blackhole ? (1-p) : p) * (0.4 + t * 0.6)
            var location = point(angle + (effect == .shadow || effect == .petals ? p * 1.5 : 0), distance)
            var particleColor = color
            var particleSize = 2 + t * 4
            switch effect {
            case .soft, .mechanical, .glitch: continue
            case .ice: particleColor = .cyan; particleSize = 3 + t * 8
            case .shadow: particleColor = index % 3 == 0 ? .red : .black; particleSize = 12 + t * 28
            case .petals: particleColor = index % 2 == 0 ? .pink : .yellow; location.y -= p * 25; particleSize = 3 + t * 7
            case .hologram: particleSize = 5 + t * 6
            case .pixels: particleColor = [Color.yellow, .mint, .pink, .cyan][index % 4]; particleSize = 4 + t * 4
            default: break
            }
            let rect = CGRect(x: location.x, y: location.y, width: particleSize, height: effect == .petals ? particleSize * 0.5 : particleSize)
            let path = [.pixels, .hologram, .ice].contains(effect) ? Path(rect) : Path(ellipseIn: rect)
            if effect == .hologram {
                context.stroke(path, with: .color(particleColor.opacity(fade)), lineWidth: 1)
            } else {
                context.fill(path, with: .color(particleColor.opacity(fade * (effect == .shadow ? 0.22 : 0.85))))
            }
        }
    }
}

struct ThemeTexture: View {
    let theme: DeskTheme
    var body: some View {
        Canvas { context, size in
            let ink = theme.accent.opacity(theme == .horror ? 0.16 : 0.09)
            switch theme {
            case .blueprint, .terminal, .cyber:
                let step: CGFloat = theme == .blueprint ? 16 : 5
                var lines = Path()
                for y in stride(from: CGFloat(0), to: size.height, by: step) {
                    lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y))
                }
                if theme == .blueprint {
                    for x in stride(from: CGFloat(0), to: size.width, by: step) {
                        lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }
                context.stroke(lines, with: .color(ink), lineWidth: 0.5)
            case .vintage, .forest, .gentle:
                for i in 0..<120 {
                    let x = CGFloat((i * 71) % 997) / 997 * size.width
                    let y = CGFloat((i * 137) % 991) / 991 * size.height
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(ink))
                }
            case .horror:
                for i in 0..<7 {
                    var crack = Path()
                    let x = Double(i) * size.width / 6
                    crack.move(to: CGPoint(x: x, y: 0))
                    crack.addLine(to: CGPoint(x: x + 12, y: size.height * 0.12))
                    crack.addLine(to: CGPoint(x: x - 8, y: size.height * 0.22))
                    context.stroke(crack, with: .color(ink), lineWidth: 1)
                }
            case .pixel:
                context.stroke(Path(CGRect(x: 4, y: 4, width: max(0,size.width-8), height: max(0,size.height-8))), with: .color(ink), lineWidth: 2)
            case .moon:
                for i in 0..<35 {
                    let x = CGFloat((i * 73) % 997) / 997 * size.width
                    let y = CGFloat((i * 191) % 991) / 991 * size.height
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(ink))
                }
            default: break
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
