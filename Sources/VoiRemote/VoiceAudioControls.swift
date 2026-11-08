import VoiRemoteCore
import VoiRemoteMac
import SwiftUI

struct VoiceAudioControls: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var reminder: VoiceLimitHUDController
    @ObservedObject var audio: RemoteAudioRuntime

    var body: some View {
        Toggle("启用虚拟麦克风", isOn: Binding(
            get: { store.configuration.remoteAudioEnabled },
            set: { value in store.update { $0.remoteAudioEnabled = value; if value { $0.voiceEnabled = true } } }
        ))
        .toggleStyle(.switch).controlSize(.small)
        Text("把遥控器麦克风的声音送入所选虚拟麦克风，供输入法识别；同时启用语音触发。")
            .font(.callout).foregroundStyle(.secondary)
        if store.configuration.remoteAudioEnabled { enabledOptions }
    }

    private var enabledOptions: some View {
        Group {
            HStack {
                Picker("虚拟麦克风", selection: Binding(
                    get: { store.configuration.selectedVirtualInputUID ?? "" },
                    set: { value in store.update { $0.selectedVirtualInputUID = value.isEmpty ? nil : value } }
                )) {
                    Text("请选择设备").tag("")
                    ForEach(audio.devices) { device in Text(device.name).tag(device.uid) }
                    if let uid = store.configuration.selectedVirtualInputUID, !audio.devices.contains(where: { $0.uid == uid }) {
                        Text("已保存的设备当前不可用").tag(uid)
                    }
                }
                Button { audio.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(InterfaceInspection.enabled).help("刷新音频设备").accessibilityLabel("刷新音频设备")
            }
            if audio.devices.isEmpty {
                if InterfaceInspection.enabled {
                    Text("界面预览不连接音频设备").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("未找到 MiRemoteV 2ch 或 BlackHole 2ch", systemImage: "speaker.slash")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("查看虚拟麦克风安装说明", destination: URL(string: "https://github.com/ExistentialAudio/BlackHole#installation-instructions")!)
                }
            }
            Text("按住遥控器语音键说话，并在输入法中选择同一个虚拟麦克风。应用不负责安装虚拟设备。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("RC003 语音时限提醒", isOn: Binding(
                    get: { store.configuration.voiceLimitReminderEnabled },
                    set: { value in store.update { $0.voiceLimitReminderEnabled = value } }
                ))
                Spacer()
                Button("预览") { reminder.preview() }.buttonStyle(.borderless)
            }
            if store.configuration.voiceLimitReminderEnabled {
                HStack {
                    Stepper("展开操作提示：语音开始后 \(store.configuration.voiceLimitReminderStartSeconds) 秒", value: Binding(
                        get: { store.configuration.voiceLimitReminderStartSeconds },
                        set: { value in store.update { $0.voiceLimitReminderStartSeconds = value } }
                    ), in: VoiceLimitIndicator.startSecondsRange)
                    Button("5 秒测试") { store.update { $0.voiceLimitReminderStartSeconds = 5 } }
                        .buttonStyle(.borderless).disabled(store.configuration.voiceLimitReminderStartSeconds == 5)
                    Button("恢复默认") { store.update { $0.voiceLimitReminderStartSeconds = VoiceLimitIndicator.defaultStartSeconds } }
                        .buttonStyle(.borderless).disabled(store.configuration.voiceLimitReminderStartSeconds == VoiceLimitIndicator.defaultStartSeconds)
                }
                Picker("固定回退位置", selection: Binding(
                    get: { store.configuration.voiceLimitReminderPosition },
                    set: { value in store.update { $0.voiceLimitReminderPosition = value } }
                )) {
                    Text("屏幕底部居中").tag(VoiceLimitReminderPosition.bottomCenter)
                    Text("屏幕右下角").tag(VoiceLimitReminderPosition.bottomTrailing)
                }
                Text("倒计时随本段语音持续显示；“松开再按”默认在最后 10 秒展开，最后 5 秒变红。展开时间可设为语音开始后 0–55 秒，0 秒立即展开。按约 60 秒单段时限估算，不会延长录音，也不影响键盘直接触发的语音。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("首次先等微信语音胶囊出现再并排显示，最多等待 2 秒；无法定位时使用固定位置。预览立即显示，演示 5 秒内展开，不查询微信窗口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("音频连接", value: audio.status)
            Button("重新连接音频") { audio.retry() }.disabled(InterfaceInspection.enabled)
            DisclosureGroup("测试与设备状态") {
                LabeledContent("设备状态", value: audio.outputStatus)
                LabeledContent("收到音频", value: "\(audio.progress.packets) 包 · \(audio.progress.decodedSamples) 样本")
                LabeledContent("送入设备 / 设备消费", value: "\(audio.progress.output.submittedSamples) / \(audio.progress.output.consumedSamples) 样本")
                LabeledContent("待输出", value: "\(audio.progress.output.pendingSamples) 样本")
                LabeledContent("最后音频", value: audio.progress.secondsSincePacket.map { "\($0) 秒前" } ?? "尚未收到")
                LabeledContent("输入信号", value: audio.progress.signalChanging ? "有变化" : "当前变化较小")
                LabeledContent("播放进度", value: audio.progress.output.playback.clockFrame.map { String(format: "%.1f 秒", $0 / 16000) } ?? "未播放")
                LabeledContent("时序恢复 / 迟到缓冲", value: "\(audio.progress.output.playback.timingRecoveries) / \(audio.progress.output.playback.lateSchedules) 次")
                Text("计数仅保留在内存，每秒刷新；设备消费不等于输入法已收到声音。").font(.caption).foregroundStyle(.secondary)
                Button(audio.testingTone ? "正在发送测试音…" : "发送测试音到虚拟麦克风") { audio.playTestTone() }
                    .disabled(!audio.canTestTone)
                Text("测试音只发往所选设备，开始语音时会自动停止。应用不安装音频驱动，也不重启系统音频服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
