# 构建与安装

## 工具链

macOS 14+，安装包含 Swift 6 的 Command Line Tools。根目录的 `Package.swift` 是唯一工程定义；没有 `.xcodeproj`、私有包或网络依赖。`scripts/toolchain.sh` 为当前进程设置 `DEVELOPER_DIR`，默认使用独立 CLT，不修改系统的开发者目录。

脚本使用 CLT 随附的 SwiftPM 默认构建系统。Formula 设置 `VOIREMOTE_HOMEBREW_BUILD=1`，把 SwiftPM 缓存限制在构建目录并关闭其子进程的嵌套 sandbox-exec；Homebrew 自身的构建沙箱仍生效。普通构建不关闭 SwiftPM 沙箱。

链接时明确区分最低运行要求和构建 SDK：前者取自 Info.plist 的 macOS 14.0，后者由选定 CLT 的 `xcrun --sdk macosx --show-sdk-version` 自动取得，不硬编码开发机版本，也不拿运行系统版本冒充 SDK。这样既保留旧系统支持，也让新系统使用对应的原生窗口外观。`verify-app.sh` 检查 Mach-O `LC_BUILD_VERSION` 的这两个字段，避免 Swift Build 把最低版本误写为 SDK 后仍被当作成功构建。原因见 [SDK 元数据决策](../.agents/notes/implemented/bug-fix/2026-10-28-linked-sdk-metadata.md)。

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools xcrun swift --version
make test
make build
./scripts/verify-app.sh
```

默认 Release 产物为 `dist/VoiRemote.app`，只包含当前架构。`CONFIGURATION=debug make build` 可生成调试包。脚本将 `VERSION` 写入 Info.plist，以临时签名生成可运行 bundle；临时签名不等于 Developer ID、公证或可公开分发的正式包。

必须先退出从目标路径运行的 app 再重建；构建脚本会拒绝覆盖运行中的应用。本地默认临时签名的指定要求绑定代码摘要，更新构建可能使原有 TCC 授权不再匹配。运行时用 Security API 检测磁盘与进程代码不一致并暂停映射，避免把旧进程权限误当作新构建状态。不得修改隐私数据库替用户授权；用户明确选择的固定身份试验见下节。

macOS 27 将“辅助功能”权限页改名为“设备控制和数据访问”，旧的 Privacy_Accessibility deep link 仍指向该页。输入监听未允许时直接使用 IOHIDRequestAccess，未获允许时再调用 CGRequestListenEventAccess。未知状态的首次请求不立即打开设置抢走系统提示的焦点；原状态已拒绝时打开设置，另有独立设置入口。已允许时只提供设置入口；macOS 不保证重复弹窗或自动列出条目。监听检查返回 granted 也可能来自设备控制授权，不能据此确认输入监控列表中的独立条目。运行时以实际 HID 打开和报告接收结果验证设备可用性；失败则恢复原生映射并停止。

交互授权验证时仅保留一个构建路径。临时 Homebrew 安装使用同一 Bundle ID，曾影响系统对授权目标的选择；先完成源码安装验证并清理临时副本，再固定 `/Applications/VoiRemote.app` 进行权限与硬件验收。不要为触发首次弹窗擅自重置 TCC 或改动隐私数据库。

获用户明确授权后，可用 `tccutil reset ListenEvent dev.voiremote.app` 仅清理本应用输入监控选择；先退出应用，再重开相同构建。此命令成功仅证明重置请求成功，不证明系统弹窗恢复；当前机器的重试结果见 [M1 记录](validation/2026-10-27-m1.md)。不要扩大为全应用或其他权限重置。

### 开发签名选择

默认仍是临时签名，其 designated requirement 绑定本次代码哈希，代码变化后系统可能不再接受旧授权。可通过 `CODE_SIGN_IDENTITY='证书名称或指纹' make build` 使用本机已有的代码签名身份；保持同一身份可让系统识别后续版本。该选项不创建证书、不改钥匙串，也不自动签名公证或发布。

无线麦的源码开发构建为临时签名显式指定 `identifier` 识别规则，本项目提供相同语义的可选模式：`VOIREMOTE_STABLE_ADHOC_IDENTITY=1 make build`。它只按 `dev.voiremote.app` 匹配、没有签名者约束，其他程序也能声明同一标识。本地普通构建仍默认关闭；用户明确选择后，0.2.14的Homebrew构建开启该试验，初次与来源信息写入后的最终签名共用`sign-app.sh`。

最终应用声明`identifier-only-adhoc-v1`策略，核验脚本同时检查严格签名和实际指定要求。`./scripts/check-signing-identity.sh [APP]`用离线副本验证不同代码哈希、来源信息重签、错误标识与内容损坏；不启动应用或更改系统授权。完整性与源码归档摘要不能代替签名者认证；此方式没有Developer ID、公证或Gatekeeper批准。本机macOS27.2已分别验证首次迁移和0.2.14到0.2.15真实远端升级的两项授权保留；其他系统仍需独立验收，见[试验记录](validation/2026-10-29-certificate-free-identity.md)。

改变签名方式后，已有授权可能仍须重新关联当前构建。稳定签名用于避免后续身份漂移，不等于保证系统首次弹窗出现；必须另行记录实际授权和按键结果。

`make run` 会打开设置窗口。菜单栏可重开窗口；关闭窗口不会退出进程。执行程序支持 `--version`、`--self-check`；`--smoke-test` 启动真实 AppKit/SwiftUI 窗口，确认存在后自行退出，不访问硬件。`--smoke-test-reminder` 单独预览无声时限浮条并检查紧凑/展开/隐藏及非激活/穿透属性，并用注入几何检查真实面板的紧急态和稳定定位，使用独立配置，不要求设置窗口自动出现；仅解锁后执行，不能代替全屏、多屏和真实遥控器检查。`--smoke-test-background`检查设置窗口创建前已建立配置订阅，同样不访问硬件。

提醒smoke还用注入的数字几何检查真实面板跟随和回退，不查询其他应用窗口。需要只读实测本机微信窗口时，单独运行`./scripts/probe-wetype-windows.sh [秒数]`；默认60秒、最大300秒，用户自行操作输入法，探针只输出数字窗口归属、层级、透明度及边界，不读标题、文字或音频。输出留在本地忽略目录，不自动上传。

## 单 Cask 源码安装

源码与 tap 位于同一个 [public 仓库](https://github.com/realDGD/VoiRemote)，仅维护 `Casks/voiremote.rb`。Cask 固定完整 commit、归档 URL 与 SHA-256；structured preflight 运行 `scripts/build-cask.sh VERSION COMMIT SHA256`，在下载的源码中执行核心/适配器检查和独立 CLT 编译。

```sh
brew tap realdgd/voiremote https://github.com/realDGD/VoiRemote.git
brew install --cask realdgd/voiremote/voiremote
voiremote --self-check
open /Applications/VoiRemote.app
```

需要时仅信任这个 Cask：`brew trust --cask realdgd/voiremote/voiremote`。该第三方 tap 使用安装期源码编译，不声称属于官方 homebrew/cask 的预编译分发模式。Homebrew structured steps 在其 sandbox 内执行构建；SwiftPM 缓存位于归档自身 `.build`，只关闭 SwiftPM 嵌套 sandbox，不关闭 Homebrew sandbox。

构建把版本、源码 commit、归档 SHA-256 和签名策略写入 `Contents/Resources/HomebrewSource.plist` 后，通过统一入口重新临时签名。来源标记本身也在签名密封范围内；核验会检查声明策略与最终身份一致。旧版没有策略字段时只报告旧版检查，不宣称固定身份已验证。标准 app artifact 将唯一 app 移入 Applications，在 staged 位置保留链接；postflight 清理 `.build` 与 `.swiftpm`。启动命令沿受管理链接定位实际 appdir，不保留 keg app，也不安装 Formula。

安装后可在源码工作区执行只读验收（它不安装本地源码）：

```sh
./scripts/verify-homebrew-install.sh
```

脚本从已安装的远端 Cask 元数据取得期望来源，核对固定 GitHub URL、版本、签名资源标记、严格签名、配置自检、CLI、没有旧 Formula/Cask、没有第二个 app 目录或 `.build`。也可显式传 `VERSION COMMIT SHA256 [APPDIR]`；自定义 `--appdir` 的安装应传实际目录。`brew test` 只支持 Formula，不将其失败或跳过伪报为 Cask 验收。

更新及卸载：

```sh
brew update
brew upgrade --cask realdgd/voiremote/voiremote
brew uninstall --cask --zap realdgd/voiremote/voiremote
```

一个卸载命令同时移除 app、启动命令、staged 记录。加 `--zap` 清本应用偏好、ByHost、缓存、保存状态与 Application Support；去掉保留设置。退出和恢复未完成时不能丢弃恢复记录。系统 TCC、音频驱动与其他应用不在清理范围。

分发方式的取舍见 [Agent Note](../.agents/notes/implemented/architecture/2026-10-28-single-source-cask.md)，实际迁移、远端安装与卸载结果见[验证记录](validation/2026-10-28-single-source-cask.md)。

旧双项版本的迁移命令见 [README](../README.md)。迁移不自动在后台卸载旧包；用户明确要求后才操作本机安装。

### 生成与发布

`make homebrew` 只生成忽略目录内的本地归档和 Cask，用于静态打包检查，不用于安装验收。发布先提交并推送源码，再生成固定该提交的远端配方：

```sh
ruby scripts/prepare-homebrew.rb --remote "$(git rev-parse HEAD)" --tap realdgd/voiremote
```

生成器要求干净工作树、当前 HEAD 完整 SHA，实际下载 GitHub 归档计算校验和。审阅 `dist/homebrew-remote/tap/Casks/voiremote.rb` 后复制到仓库根目录 `Casks/`、单独提交推送。只有一个 public 仓库；后续纯文档提交不改变 app 的固定构建来源。没有选定许可证，不生成证书、公证或二进制 Release。

## 持续集成

[CI](../.github/workflows/ci.yml) 保留 Linux 文档/全历史脱敏/Gitleaks/actionlint，以及 macOS 15 arm64/Intel 独立 CLT。两个架构均从 `https://github.com/realDGD/VoiRemote.git` 新建 tap，下载远端固定源码，执行单 Cask 安装、只读验收、实际卸载与 zap 检查。不把 checkout、file URL 或本地生成归档用于安装。原始诊断和二进制不上传；权限、真机语音和最低 macOS 14 仍单独验收。

## 本轮诊断入口

`--list-loopback-devices` 只读列出兼容回环设备名称。`--smoke-test-guide` 以不访问 HID/蓝牙的模式检查设置与拖入帮助面板可见；配合 `--preview-directory /绝对路径` 可导出应用自己的视图预览，缓存图不代替完整原生交互检查。

macOS 检查程序的 `--loopback-output-smoke` 是单独、显式的硬件检查：仅向已识别回环设备写入 800 个静音样本，等待排空，并比较前后系统默认设备快照。普通 `make test` 不运行此硬件检查。

`VoiRemote --check-input-catalog` 只读检查真实输入目录、分类及 CoreAudio listener 注册/清理，比较前后默认设备并只输出数量，不打印 UID、设备名或地址，不切换设备、不读取音频。应用的输入优先功能须由用户开启，默认关闭；普通检查与 UI smoke 使用模拟或禁用硬件的运行时。M3 的真实默认输入切换须另行按硬件矩阵验收，不能以该诊断命令代替。

`./scripts/probe-input-runtime.sh` 是独立 CLT 模拟探针：编译实际输入协调器与运行时，全部注入固定模拟系统，观察 6.2 秒空闲、2.2 秒关闭后回调、1000 次即时会话循环与初始化失败恢复。不创建 app、不访问 CoreAudio 设备、不写真实系统输入；产物在 `.build/probes/input-runtime/`。它会报告已知的菜单恢复缺口，退出成功不表示该缺口已修复；结果边界见[运行时审查](research/2026-10-28-idle-runtime-audit.md)。不加入普通 CI 的计时验收。

## 独立设置预览

`./scripts/prepare-ui-preview.sh` 用同一 CLT 构建独立的 `.build/ui-preview/VoiRemote.app`，使用专用 Bundle ID 和配置域，不覆盖安装版，也不启动 HID、蓝牙、音频或默认输入写入。它支持实际原生点击与快捷键录入，配置仅用于本次检查，退出时清除。左栏底部明确标记“界面预览”。重建前先退出该预览；脚本拒绝覆盖正在运行或身份不符的副本。

预览副本的 `--smoke-test --preview-directory <输出目录>` 可导出自身视图并自动退出。截图缓存只用于布局检查，不能替代真实控件交互或硬件验收。预览中不要点击系统授权/系统设置入口进行授权测试；真实权限仍需使用固定的实际安装路径。
