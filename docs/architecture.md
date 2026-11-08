# 架构

## 模块

- `VoiRemoteCore`：配置、映射、手势、语音键会话、ATVV 数据格式、IMA/DVI 解码及输入优先策略，不依赖 UI、蓝牙、CoreAudio 或系统事件发送。
- `VoiRemoteMac`：设备与权限、原生按键租约、系统动作、CoreBluetooth、回环设备与音频输出。
- `VoiRemote`：SwiftUI/AppKit 原生设置、配置保存和操作引导。
- `Tests/VoiRemoteChecks`、`Tests/VoiRemoteMacChecks`：不依赖 XCTest 的检查入口。macOS 模拟检查注入设备服务与事件出口，不向桌面发送按键。
- `scripts/` 与 `packaging/homebrew/`：独立 CLT 构建、bundle/仓库检查及源码 Cask 生成；公开 tap 只有根目录 `Casks/voiremote.rb`。Cask 在源码内编译、记录签名来源。非交互 vendor installer 拥有 app 搬移和最终路径上的登录项恢复；卸载脚本验证凭据后退回 app 到暂存区，Homebrew负责最终清理或回滚。命令链接仍由标准binary artifact管理；暂存区稳态只保留指向Applications实体app的别名，构建缓存清除，不保留Formula/keg app。0.2.14源码与Cask按用户选择采用固定标识ad-hoc身份，初次与来源信息后的签名统一并核验实际要求；只约束标识、不认证签名者，实际迁移与TCC持久性仍以独立验证记录为准。
- `.agents/notes/`：持久决策；`.agents/plans/`：实施清单；`.agents/skills/`：项目检查与 Note 工作流。

## 配置与界面

`ConfigurationStore` 在 MainActor 上保存整个配置，存储键保持 `configuration.v1`，应用标识为 `dev.voiremote.app`。数据 schema 为 6，保留0–55秒、默认50秒的 `voiceLimitReminderStartSeconds`，当前语义为操作提示展开时机，倒计时本身从真实语音开始显示。保留schema5的有界 `GestureTiming` 与稀疏逐键 `ButtonBehaviorOverride`，缺省保留300/550/450/80ms与关闭的长按/双击连发选项。旧时序与次级手势优先级不变，无修饰自定义方向/退格现在与内置动作同样自动连发。保留schema4的时限提醒配置、独立 `voiceEnabled` 和默认关闭的 `remoteAudioEnabled`。schema3迁移不改变原有开关。读取 schema 1/2 保留原设置；原映射已开则迁移语音触发为开，不自动启用遥控器音频。未知版本、重复绑定、无效快捷键、越界时序及重复逐键策略拒绝加载，保留原始数据并暂停编辑。

设置窗口由 AppKit 按需创建并承载 SwiftUI，菜单栏场景常驻。`AppPresentation` 仅跟踪设置窗口：打开时切换 regular，关闭后按本机 Dock 偏好切回 accessory；提醒与授权面板不改变该状态。系统登录项采用 `SMAppService.mainApp`，默认关闭；登录 Apple Event 或 `--background` 不创建设置窗口，首次向导延后到用户打开设置。登录项状态与 Dock 偏好不进入便携配置。`LoginItemMaintenance`仅在卸载/安装CLI运行：注销前持久化已生效的开启状态，安装后恢复并核对实际状态；失败保留恢复请求，用户显式关闭则取消。普通启动不重注册，系统禁用不自动解除，恢复标记不进入配置导出。新身份首次只读迁移旧偏好原始配置和向导标记，不覆盖新配置；旧系统权限不能迁移。

原生五页设置使用 `NavigationSplitView`。映射页左侧常驻遥控器，右侧语音卡置顶，普通键按三组显示三列；点击示意图定位对应行，快捷键图标直接录入，动作菜单内可清除。录入器只处理当前窗口，候选确认前不改配置。遥控器图由 SwiftUI 几何绘制，不包含品牌图片。`SetupWizard` 使用临时检测模式，复用 HID 链路而不执行普通映射或语音触发；仅完成时合并选择，取消恢复原状态。`SetupInputCheck` 限定本次阶段与同一来源的成对事件，断连或停止清除结果，不证明音频或输入法可用。

SDK 27 的裸 `@State` 依赖 CLT 不附带的 SwiftUIMacros；`ViewState<Value>` 显式引用公开 `SwiftUI.State<Value>` 包装器。不能未经独立 CLT 验证改回裸宏。

首次设置窗口就绪后，ConfigurationStore在无配置且没有 `initialSetup.finished.v1` 时自动展示向导。展示仅写 `setup.pending.v1`，保存或明确跳过才标记结束并清除进行中状态；进程退出、权限重启和窗口关闭不等于完成。进行中的手动向导在有旧配置时也会恢复到准备页，未确认草稿不持久化。标记不进入配置schema和便携导出，不当作硬件验收；读取错误时不自动弹出，不覆盖原始数据。zap恢复首次流程。0.2.9的“已展示”不能区分完成与中断，无配置时需重新引导一次。

向导自身的AppKit sheet通过嵌入NSView在挂载时设 `preventsApplicationTerminationWhenModal=false`，移除时恢复原值，使系统授权的退出重开和正常退出能进入应用既有有界清理代理；不改变其他模态窗口，不增加自动重启进程或后台守护。

`ConfigurationTransfer` 拥有可移植 JSON 格式及大小、schema 和映射校验；UI 使用原生文件面板与替换确认，移除设备身份并关闭导入能力。`SetupWizard` 的四步草稿与可选检查分开，跳过不产生硬件成功证据。`MenuAudioInputs` 直接观察两个音频所有者，复用既有输入目录和显式 `userSelection` 请求；手动切换不创建语音所有权，语音/恢复期间互斥。

## 设备、权限与事件

发现阶段只读 IORegistry 属性，不实例化 HID user client。接管时 `HIDRemoteMonitor` 才打开限定 VID/PID 的原始键盘报告通道。`XiaomiRemote` 解析三个 little-endian 16-bit usage，支持 report 1 的 6/7 字节布局，语音 0x3E 不进入普通手势。`ButtonGestures` 使用外部单调时间：默认双击 0.30 秒、长按 0.55 秒；可重复动作 0.45 秒后每 0.08 秒重复，不补发积压。这些时序可配置；每个手势在首次按下时锁定动作和策略，长按、双击锁定与重复分别处理。`RemoteMappingRuntime` 根据 `nextDeadline` 在主运行循环 `.common` 模式只安排一个按需单次计时器，不再固定20ms扫描普通手势；取消或改期递增代次，旧回调不能补发。映射、时序或逐键策略变化清空待执行普通手势，不因这些参数变化结束语音。详见[高级手势决策](../.agents/notes/implemented/feature/2026-10-29-advanced-gesture-behavior.md)。

`NativeKeyLease` 按服务与所属源写入、验证和恢复原生映射。恢复日志 v2 记录本次源范围，兼容旧 v1；仅开启语音时只接管语音键，普通映射开而语音关时不接管语音键。日志在设备写入前原子保存；外部软件后来的修改保留。理由见 [设备租约决策](../.agents/notes/implemented/architecture/2026-10-27-device-scoped-key-lease.md)。

`PermissionProbe` 在串行后台队列处理同步 TCC 查询与请求，主线程交付状态，不堆积轮询。监听已允许不等于独立输入监控条目，可能来自设备控制授权。只在用户请求时调用公开授权 API；失败时可打开真实设置，并以原生可拖动 app URL、图标和箭头辅助人工添加，不伪造系统授权框。相同状态不持续发布，避免无意义地重建整个设置页。

`SystemActionSender` 成对发送普通键、媒体键和独立修饰键，持有物理冲突检查与释放。释放时重建本次修饰键家族的真实物理状态，清掉快照中可能残留的合成标记，保留另一侧及其他修饰键。`RemoteMappingRuntime` 统一处理 HID、设置、权限、断连、休眠和退出；语音持有期间暂停普通映射。

## 音频代码链路

`RemoteVoiceBluetooth` 管理单个 RC003 候选，订阅 Audio/Control 通知并确认支持 16 kHz 的能力后才 ready；初始化超时 8 秒，失败后 3 秒重建连接。旧连接的 delegate 被清理，不跨连接处理回调。只连接明确设备名或匹配 ATVV 服务的已限定候选；不记录外设 UUID、地址或完整数据。

核心 `RemoteVoiceDecoder` 处理高半字节优先的 IMA/DVI、分片和 predictor/index 同步，拒绝异常尺寸。解码检查使用合成固定样例，不包含真实录音。

`LoopbackDevices` 以已知 UID 加双向声道验证识别 MiRemoteV 2ch / BlackHole 2ch。瞬时 AudioDeviceID 仅存在适配器，配置保存 UID。`LoopbackWriter` 在串行队列中拥有独立的 Audio Queue 播放后端，按 UID 显式绑定所选回环，接收 16 kHz 单声道 PCM 并由系统转换为设备格式。它不依赖 AVAudioEngine 的默认输入/输出图，系统默认输入变化不会重新选择输出目标。缓冲消费与播放结束分别确认；只有异步停止完成才报告尾音排空，超时或取消立即停止。没有回退扬声器或写系统默认输入/输出的路径，设备失效或队列溢出时停止。

`RemoteAudioRuntime` 拥有路由、协议连接和会话代际。开始前确认音频与 HID 接管准备，再发送触发键；结束保留 120 ms 尾部通知，排队 PCM 播放完成后释放，排空最长等待 1 秒。取消、断连或失效立即清理。快速重按会中断旧排空，新会话等协议 start 后接收数据，避免旧音频混入。测试音在内存生成，只写所选回环，真实语音优先并取消测试音。

以上为代码接入事实，不能替代实际说话、首尾音、低延迟及目标输入法验收。

## 语音会话临时输入

`AudioInputPriority` 仅为活动语音事务捕获按下前的输入 UID，空闲观察不建立事务。按住时目标仍需已知驱动 UID/声道验证；恢复精确使用快照中的设备，包括其他虚拟或未知输入，只有原设备不可用才选实体回退。`record` 不因按住期间的外部抢占改写快照；松开后的新选择独立保存，必要时补偿确认窗口内的旧延迟写入。旧事务未完成的快速重按延续返回基线。

`CoreAudioInputSystem` 拥有系统和设备属性 listener。写入前重新解析可用输入、验证优先目标并比较来源；只写 DefaultInputDevice。`InputPriorityCoordinator` 将活动来源从设备 ready 改为活动语音，分离请求、确认和恢复。读回窗为 1 秒；重试和抢占写入间隔至少 0.5 秒，同一意图三次失败后暂停；真实按下/结束边界不等待旧的限频时间。状态只在新读回有效且无 pending 时允许语音开始。

`AudioInputPriorityRuntime.beginVoiceSession` 读取新快照并等待确认后回调，配置和音频 ready 本身不会接管；`endVoiceSession` 恢复。`RemoteAudioRuntime.prepareInput` 接入该门禁，等待期间以 `VoiceStartBuffer` 有界保留最多 32000 个单声道 PCM 样本。确认后才发送锁定的触发键、输出早到音频并启动协议；取消清除缓冲，代际阻止旧完成回调复活语音。

只有 HID 按下能开始会话，ATVV open 不能补开或重试已结束的会话。物理松开保留原有尾音与有界排空，完成后先释放实际持有的触发键，再结束输入事务。失效、向导、休眠和退出撤销活动来源，正常退出为已接受写入和恢复保留 3.5 秒。未知结果或无恢复设备时不伪报成功；停止后的回调不能清掉最终错误。

所有 UID、返回快照和所有权只在进程内，不写录音、输入文字或原始设备标识日志。CoreAudio 没有原子 compare-and-set，已接受请求不能撤回，确认窗口外的驱动延迟、强制结束和系统崩溃仍不保证恢复。当前生产音频限制一个所有者，真实遥控器与目标输入法验证独立记录。当前理由见 [语音输入事务决策](../.agents/notes/implemented/feature/2026-10-27-voice-input-transaction.md)，旧在线优先方案保存在归档 Note。

工具链与分层理由见 [CLT 决策](../.agents/notes/implemented/architecture/2026-10-27-swift-clt-foundation.md)。

输出健康检查在 `LoopbackWriter` 串行队列完成，空闲不要求队列running；有待播数据才观察运行和消费/时钟停滞。`RemoteAudioRuntime` 每秒维护设备、健康与收包间隔，统一拥有1/2/4秒、最多3次的恢复预算，连续健康10秒才复原预算；BLE不再内部无限重连，查找到能力读取总计8秒截止。故障先释放触发与恢复输入；重新ready不代表恢复旧语音。连接、路由和按键各自代次隔离旧回调。

系统willSleep暂停音频和HID所有权，作废配置/健康/传输代次；didWake重新检查设备与权限，音频不使用旧遥控器计数开连。每个来源先报告松开语音键，再允许新语音。暂停期间不轮询设备或重新连接，退出后唤醒不会复活。锁屏与用户会话切换不在这次实现边界内；见[生命周期决策](../.agents/notes/implemented/feature/2026-10-28-system-sleep-audio-lifecycle.md)。


## RC003临近时限提醒

`RemoteAudioRuntime`发布`VoiceLimitIndicator`快照，只由真实ATVV START建立单调起点；重复START不重置，报告的上限STOP使用中性结束态，主机关闭确认不产生到时提示。Core策略不创建计时器或系统副作用。`VoiceLimitReminderRuntime`只在下一次展示变化时安排一个deadline，代次作废旧唤醒/隐藏任务；从真实START起每秒更新倒计时；`showsReleaseHint`按原有0–55秒设置控制操作提示，默认50秒展开，最后5秒图标变红。估算60秒不结束语音，停止事件仍由音频所有者处理。

`ApplicationDelegate`强持有`ConfigurationStore`、`RemoteMappingRuntime`及`VoiceLimitHUDController`，在delegate初始化时建立配置/音频订阅。配置应用不依赖任何窗口onAppear，菜单栏冷启动和关闭设置后仍有效。控制器延迟创建一个NSPanel与复用的SwiftUI内容，非激活、穿透、无声；真实段开始固定回退屏幕，屏幕消失时重选。睡眠取消，唤醒不恢复旧段；退出清理任务、订阅、观察者和窗口。开关同时要求语音及虚拟麦克风启用，预览独立于设备。RC003档案由用户明确开启，不能用共享HID身份自动确认型号。实际原因与未覆盖场景见[决策](../.agents/notes/implemented/feature/2026-10-28-rc003-voice-limit-indicator.md)。

`WeTypeCapsuleFollower`在真实段可见期间，每次读完200ms后安排下一次查询；后台`SystemWeTypeWindowSource`最多一个在途窗口列表查询，只提取微信进程的数字元数据。估算到60秒仍跟随，实际STOP、松开、隐藏、预览、取消、睡眠和退出不续扫。`WeTypeCapsuleMatcher`按3.0.0/3.0.1的已知紧凑轮廓保守匹配，失败或歧义清除锚点；`capsuleBounds`使用该版本截图档案估算透明窗口内底部88×36pt按钮及64pt底边距。

Core的`VoiceReminderPlacement`转换CG/AppKit坐标，右侧并排优先、再左侧，垂直对齐绿色按钮中心，并避开整个上方文字区域；无法并排时尝试上下，不安全则回退固定位置。面板始终预留192×34pt安全空间，SwiftUI只绘制104pt短胶囊，提示出现时以0.24秒展开到164pt；结束或接近时限等较长状态使用192pt以免截字；左侧布局从靠近绿色按钮的一边向外展开，系统减少动态效果时不动画。预留空间防止展开时跳到另一侧或压住文字，透明区域保持鼠标穿透。`screenIndex`按绿色按钮覆盖面积选择屏幕；控制器记录该屏幕供定位丢失后的固定回退使用，忽略鼠标后续跨屏移动。仅首次未识别时以鼠标屏幕选择回退。面板使用与已识别微信语音窗口相同的`maximumWindow-2`层级，取代普通floating层级，不激活窗口或反复抢前台。`WeTypeCapsuleFollower`同时发布锚点和首次显示就绪状态，真实段先等待首个有效锚点或独立的2秒截止；就绪后才创建/显示面板，先摆放再orderFront，避免先显示固定位置再跳到目标。已就绪后丢失锚点仍立即回退，预览不等待。首次截止与轮询均受代次和取消保护，松开、关闭、睡眠、换段及预览切换不能留下延迟闪现。位置/就绪订阅统一尝试呈现，已经可见时只移动面板；SwiftUI直接观察现有提醒运行时，只有布局方向改变时替换根视图，不每秒或每200ms重建根视图；展示快照、代次和取消后的复核防止旧查询或订阅重入复活旧段。

无需读文字、剪贴板或申请新权限，不改变音频/输入事务。代价是开启提醒后的定位覆盖整个语音段，而非仅最后10秒；空闲、关闭能力和键盘直接触发仍无定位查询。理由见[跟随决策](../.agents/notes/implemented/feature/2026-10-29-follow-wetype-capsule.md)，新原生与真机边界见[验证记录](validation/2026-11-07-persistent-voice-countdown.md)。
