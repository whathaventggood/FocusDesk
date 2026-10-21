import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: PlanStore

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
                        Toggle("悬浮窗始终置顶", isOn: $store.alwaysOnTop)
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
                    Text("计划按每天的系统本地时间重复。拖动悬浮窗可调整位置，睡眠唤醒后会自动校准当前任务。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = store.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("FocusDesk 1.0").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("今日计划") { store.onShowPlan?() }
                }
            }
            .padding(28)
        }
        .frame(width: 440, height: 540)
    }
}
