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
                        .font(.system(size: 30)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FocusDesk 设置").font(.title2.weight(.semibold))
                        Text("让计划安静地陪你完成每一天")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("桌面小方块大小")
                                Spacer()
                                Text("\(Int(store.compactSize)) × \(Int(store.compactSize))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $store.compactSize, in: PlanStore.compactSizeRange, step: 1)
                                .accessibilityLabel("桌面小方块大小")
                            HStack {
                                Text("32 点")
                                Spacer()
                                Button("恢复默认") { store.compactSize = PlanStore.defaultCompactSize }
                                    .buttonStyle(.link)
                                Spacer()
                                Text("112 点")
                            }
                            .font(.caption)
                        }
                        Text("鼠标移入小方块展开任务，移出小方块与任务窗后自动收起。拖动方块移动位置，拖动右下角调整大小。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle("小方块与悬浮窗始终置顶", isOn: $store.alwaysOnTop)
                        Text("开启后显示在其他应用窗口上方。关闭后仍会保留在桌面，可通过菜单栏找回。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle("登录 macOS 时启动", isOn: Binding(
                            get: { store.launchAtLogin },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                        Text(store.launchAtLoginStatus)
                            .font(.caption).foregroundStyle(.secondary)
                        Button("打开系统登录项设置") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .controlSize(.small)
                    }
                    .padding(12)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("计划与设置仅保存在本机", systemImage: "internaldrive")
                        .font(.callout.weight(.medium))
                    Text("计划按每天的系统本地时间重复。小方块的位置和大小会自动保存，睡眠唤醒后会自动校准当前任务。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = store.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.needsDataRecovery {
                    Button("备份原文件并恢复默认计划…", role: .destructive) {
                        confirmRecovery = true
                    }
                    Text("恢复会重置当前计划和完成记录；损坏的原文件会先备份到本机，不会静默覆盖。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let recoveryError {
                    Text(recoveryError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("FocusDesk \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版")")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("专注记录") { store.onShowHistory?() }
                    Button("今日计划") { store.onShowPlan?() }
                }
            }
            .padding(28)
        }
        .frame(width: 440, height: 540)
        .confirmationDialog("恢复默认计划并重置完成记录？", isPresented: $confirmRecovery) {
            Button("确认备份并恢复", role: .destructive) {
                recoveryError = store.recoverWithDefaultPlan()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原文件备份成功后才会恢复。历史完成记录将重置，保留的备份可用于后续恢复。")
        }
    }
}
