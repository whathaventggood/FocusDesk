import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: PlanStore
    @State private var confirmRecovery = false
    @State private var recoveryError: String?

    private func effectSlider(_ key: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L(key)); Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : String(format: "%.1f", value.wrappedValue)).monospacedDigit()
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(L(key))
        }
    }

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
                HStack {
                    Text(store.language == .english ? "Language" : "Language / 语言")
                    Menu {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Button(language.title) { store.language = language }
                        }
                    } label: { Text(store.language.title).foregroundStyle(store.theme.accent) }
                    .menuStyle(.borderlessButton).fixedSize().padding(8)
                    .background(store.theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
                        Text(L("快捷预设")).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            ForEach(EffectIntensity.allCases) { preset in
                                Button(preset.title) { store.effectIntensity = preset }
                            }
                        }
                        effectSlider("覆盖范围", value: $store.effectConfiguration.coverage, range: 0.1...1, step: 0.01, percent: true)
                        Text(L("百分比表示扩散最终可达的屏幕面积；100% 可传播到四角。"))
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(L("精细调整")) {
                            VStack(alignment: .leading, spacing: 12) {
                                effectSlider("视觉浓度", value: $store.effectConfiguration.opacity, range: 0.1...1, step: 0.01, percent: true)
                                effectSlider("持续时间（秒）", value: $store.effectConfiguration.duration, range: 1...12, step: 0.5)
                                effectSlider("扩散速度", value: $store.effectConfiguration.speed, range: 0.6...1.6, step: 0.1)
                                Picker(L("波次数量"), selection: $store.effectConfiguration.waves) {
                                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                                }.pickerStyle(.segmented)
                                Picker(L("粒子密度"), selection: $store.effectConfiguration.density) {
                                    ForEach(0...3, id: \.self) { Text(L(["无", "少", "中", "多"][$0])).tag($0) }
                                }.pickerStyle(.segmented)
                                effectSlider("边缘余光（秒）", value: $store.effectConfiguration.edgeGlow, range: 0...6, step: 0.5)
                                effectSlider("背景压暗", value: $store.effectConfiguration.dim, range: 0...0.3, step: 0.01, percent: true)
                                Toggle(L("所有显示器"), isOn: $store.effectConfiguration.allScreens)
                                Text(L("默认仅方块所在屏幕。余光包含在总时长内，最长占总时长的 40%。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 10)
                        }
                        HStack {
                            Button(L("预览桌面特效")) { store.onPreviewEffect?() }.disabled(!store.effectsEnabled)
                            Button(L("停止特效")) { store.onStopEffect?() }
                        }
                        Text(L("特效从方块扩散，鼠标可穿透、不抢焦点、无声。可在设置或菜单停止；系统减少动态效果时保留静态提醒。"))
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
    case gentle, standard, dramatic, immersive
    var id: String { rawValue }
    var title: String { L(self == .gentle ? "轻柔" : self == .standard ? "标准" : self == .dramatic ? "夸张" : "全屏沉浸") }
    var configuration: EffectConfiguration {
        switch self {
        case .gentle: return EffectConfiguration(coverage: 0.15, opacity: 0.35, duration: 2.5, speed: 0.8, waves: 1, density: 1, edgeGlow: 1)
        case .standard: return EffectConfiguration()
        case .dramatic: return EffectConfiguration(coverage: 0.85, opacity: 0.8, duration: 5, speed: 1.15, waves: 2, density: 3, edgeGlow: 2)
        case .immersive: return EffectConfiguration(coverage: 1, opacity: 0.85, duration: 7, speed: 0.9, waves: 3, density: 3, edgeGlow: 3, dim: 0.15)
        }
    }
}

struct EffectConfiguration: Codable, Equatable {
    var coverage = 0.5, opacity = 0.55, duration = 4.0, speed = 1.0
    var waves = 1, density = 1
    var edgeGlow = 2.0, dim = 0.0
    var allScreens = false
    var normalized: Self {
        var c = self
        func clamp(_ x: Double, _ low: Double, _ high: Double, _ fallback: Double) -> Double { x.isFinite ? min(high, max(low, x)) : fallback }
        c.coverage = clamp(c.coverage, 0.1, 1, 0.5); c.opacity = clamp(c.opacity, 0.1, 1, 0.55)
        c.duration = clamp(c.duration, 1, 12, 4); c.speed = clamp(c.speed, 0.6, 1.6, 1)
        c.waves = min(3, max(1, c.waves)); c.density = min(3, max(0, c.density))
        c.edgeGlow = clamp(c.edgeGlow, 0, 6, 2); c.dim = clamp(c.dim, 0, 0.3, 0)
        return c
    }
    var tail: Double { min(edgeGlow, duration * 0.4) }
    var activeDuration: Double { duration - tail }
}

/// Integrate the circle/screen intersection so a corner origin still reaches the requested area.
enum EffectGeometry {
    static func area(size: CGSize, origin: CGPoint, radius: Double) -> Double {
        let left = max(0, origin.x-radius), right = min(size.width, origin.x+radius)
        guard right > left else { return 0 }
        let dx = (right-left)/256
        return (0..<256).reduce(0.0) { sum, i in
            let x = left + (Double(i)+0.5)*dx
            let h = sqrt(max(0, radius*radius-pow(x-origin.x, 2)))
            return sum + max(0, min(size.height, origin.y+h)-max(0, origin.y-h))*dx
        }
    }
    static func radius(size: CGSize, origin: CGPoint, coverage: Double) -> Double {
        let far = hypot(max(origin.x, size.width-origin.x), max(origin.y, size.height-origin.y))
        if coverage >= 1 { return far }
        var low = 0.0, high = far
        for _ in 0..<30 {
            let mid = (low+high)/2
            if area(size: size, origin: origin, radius: mid) < size.width*size.height*coverage { low = mid } else { high = mid }
        }
        return high
    }
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

/// One screen-sized, click-through canvas per selected monitor; no per-particle views or timers.
struct CountdownEffectView: View {
    let theme: DeskTheme
    let effect: CountdownEffect
    let configuration: EffectConfiguration
    let origin: CGPoint
    let radius: Double
    let startedAt: Date
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30)) { timeline in
            Canvas { context, size in
                Self.draw(context: &context, size: size, theme: theme, effect: effect,
                          configuration: configuration, origin: origin, radius: radius,
                          elapsed: timeline.date.timeIntervalSince(startedAt))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    static func draw(context: inout GraphicsContext, size: CGSize, theme: DeskTheme,
                     effect: CountdownEffect, configuration c: EffectConfiguration,
                     origin: CGPoint, radius: Double, elapsed: Double) {
        guard elapsed > 0, elapsed < c.duration else { return }
        let endFade = min(1, (c.duration-elapsed)/max(0.25, c.tail))
        let onset = min(1, elapsed/0.18)
        let color = theme.accent
        let screen = CGRect(origin: .zero, size: size)
        context.fill(Path(screen), with: .color(.black.opacity(c.dim*onset*endFade)))
        // A broad edge light provides a readable finish without covering text in the center.
        if c.edgeGlow > 0 {
            let edge = min(1, max(0, (elapsed-c.activeDuration*0.65)/0.4))*endFade*c.opacity
            for layer in 0..<8 {
                let inset = Double(layer)*3+2
                context.stroke(Path(roundedRect: screen.insetBy(dx: inset, dy: inset), cornerRadius: 18),
                               with: .color(color.opacity(edge*0.065*(1-Double(layer)/9))), lineWidth: 7)
            }
        }
        context.clip(to: Path(ellipseIn: CGRect(x: origin.x-radius, y: origin.y-radius, width: radius*2, height: radius*2)))
        func point(_ angle: Double, _ r: Double) -> CGPoint { CGPoint(x: origin.x+cos(angle)*r, y: origin.y+sin(angle)*r) }
        func circle(_ r: Double) -> Path { Path(ellipseIn: CGRect(x: origin.x-r, y: origin.y-r, width: r*2, height: r*2)) }
        if elapsed < 0.6 {
            context.fill(circle(22+elapsed*38), with: .color(color.opacity(c.opacity*(1-elapsed/0.6)*0.5)))
        }
        for wave in 0..<c.waves {
            let delay = Double(wave)*c.activeDuration*0.16
            let raw = (elapsed-delay)/max(0.1, c.activeDuration-delay)
            guard raw > 0, raw < 1 else { continue }
            let p = pow(raw, 1/c.speed)
            let r = 20+(radius-20)*(1-pow(1-p, 2))
            let fade = min(1, raw*8)*min(1, (1-raw)*5)*c.opacity
            // Thick translucent leading bands remain visible at desktop scale.
            context.stroke(circle(r), with: .color(color.opacity(fade*0.12)), lineWidth: 30)
            context.stroke(circle(r), with: .color(color.opacity(fade*0.32)), lineWidth: 12)
            context.stroke(circle(r), with: .color(color.opacity(fade)), lineWidth: effect == .soft ? 3 : 5)
            if effect == .mechanical {
                for tick in 0..<72 {
                    let a = Double(tick) * .pi/36+p
                    var path = Path(); path.move(to: point(a,r)); path.addLine(to: point(a,r+(tick%3 == 0 ? 20 : 9)))
                    context.stroke(path, with: .color(color.opacity(fade)), lineWidth: 2)
                }
            }
            if effect == .blackhole || effect == .shadow {
                for arm in 0..<6 {
                    var path = Path()
                    for step in 0..<60 {
                        let t = Double(step)/59
                        let pt = point(t*4+p*3+Double(arm) * .pi/3, r*t)
                        if step == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    context.stroke(path, with: .color((effect == .shadow ? Color.red : color).opacity(fade*0.45)), lineWidth: effect == .shadow ? 12 : 3)
                }
            }
            let count = [0, 48, 96, 180][c.density]
            for index in 0..<count {
                let seed = Double(index), t = Double(index%13)/13
                let a = seed*2.39996+p*(effect == .petals ? 0.5 : 0.1)
                let location = point(a, r*(0.55+t*0.45))
                let scale = min(2, max(1, radius/700))
                let particleSize = (effect == .shadow ? 18+t*24 : 3+t*7)*scale
                let particleColor: Color = effect == .ice ? .cyan : effect == .petals ? (index%2 == 0 ? .pink : .yellow) : effect == .pixels ? [Color.yellow,.mint,.pink,.cyan][index%4] : effect == .glitch ? (index%2 == 0 ? .cyan : .pink) : color
                let rect = CGRect(x: location.x, y: location.y, width: effect == .glitch ? particleSize*6 : particleSize, height: effect == .petals || effect == .glitch ? particleSize*0.4 : particleSize)
                let path = [.pixels,.ice,.hologram,.glitch].contains(effect) ? Path(rect) : Path(ellipseIn: rect)
                if effect == .hologram { context.stroke(path, with: .color(particleColor.opacity(fade)), lineWidth: 2) }
                else { context.fill(path, with: .color(particleColor.opacity(fade*(effect == .shadow ? 0.25 : 0.9)))) }
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
