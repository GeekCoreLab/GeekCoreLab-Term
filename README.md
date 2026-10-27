# Geekcore Term

跨平台终端工作区，采用 Flutter/Dart 界面与 Rust 核心。当前支持本地交互终端、串口、Telnet 和 SSH 密码/私钥认证终端，SSH 支持认证模式选择、交互式质询和按序 TCP/UDP/ICMP 端口敲门；SSH 文件区包含远端侧栏与本地/远端双栏管理器，可用 SFTP 或 SCP 上传、下载。

双栏管理器通过应用内会话传输队列执行文件任务。本机目标使用 `dart:io` 文件路径；Web 明确关闭本地目录浏览，只提供远端浏览。Linux 构建和本地文件服务测试已通过，Windows/macOS 构建与 Android/iOS 系统授权目录行为尚待平台验收。SFTP 上传失败后可重试续传，双栏 SFTP 下载支持中断后重新排队续传；SCP 与传统保存对话框下载仍缓存在内存。

## 项目结构

- `lib/`：Flutter 界面
- `crates/core/`：Rust 核心库及 Flutter Rust Bridge API
- `lib/terminal/`：终端视图、会话中心与本地会话记录
- `lib/terminal/remote_file_browser.dart`：SSH 远端文件列表与管理侧栏
- `lib/terminal/remote_file_manager_dialog.dart`、`local_file_system*.dart`：本地/远端双栏与平台文件系统边界
- `lib/terminal/remote_file_transfer.dart`、`remote_transfer_queue.dart`：SFTP/SCP 文件传输与会话内队列
- `lib/terminal/ssh_tunnel*.dart`：SSH 本地、远程及 SOCKS5 动态转发
- `lib/terminal/ssh_agent*.dart`：Linux/macOS SSH Agent 身份读取与签名
- `lib/terminal/ssh_credential_store*.dart`：SSH 凭据的平台存储适配
- `hook/`：Flutter Native Assets 构建钩子
- `系统设计方案.md`：产品范围、架构和验收目标

## 开发环境

- Flutter 3.44.9 或兼容版本
- Rust 1.98.1（通过 workspace 和核心 crate 的 `rust-toolchain.toml` 固定）
- Linux 桌面开发依赖；Windows 桌面构建需在 Windows/MSVC 环境执行
- `flutter_secure_storage` 插件的 Linux 实现需要 `libsecret-1-dev` 构建、`libsecret-1-0` 运行；Windows 构建需要 Visual Studio Build Tools 的 ATL。桌面端 SSH 凭据仍保存为当前用户私有文件。
- `flutter_rust_bridge_codegen` 2.13.0
- Rust `portable-pty` 0.9.0、`serialport` 4.10.1，Dart `dartssh2` 4.1.0 与 `xterm` 4.0.0

安装桥接代码生成器：

```sh
cargo install --locked flutter_rust_bridge_codegen --version 2.13.0
```

获取 Flutter 依赖并生成桥接：

```sh
flutter pub get
flutter_rust_bridge_codegen generate
```

若 shell 找不到 `flutter_rust_bridge_codegen`，请将 Cargo 的 `bin` 目录加入 `PATH`；Linux 默认位置为 `~/.cargo/bin`。

运行 Linux 桌面版：

```sh
flutter run -d linux
```

构建 Linux Release：

```sh
flutter build linux --release
```

运行静态分析和测试：

```sh
flutter analyze
flutter test
```

Linux 可用本机 OpenSSH 服务执行真实 SFTP 续传回环检查（需要安装 `openssh-server` 和 `ssh-keygen`）：

```sh
RUN_SFTP_RESUME_SMOKE=1 flutter test test/terminal/_sftp_resume_smoke_test.dart
```

该 smoke 只监听临时 loopback 端口，并在测试结束时删除临时服务密钥和测试文件；覆盖下载续传、SFTP 上传失败后续传、取消 SFTP 上传/下载以及取消后的连接可用性。交互式 SSH 输入可用另一个 loopback smoke 检查：

```sh
RUN_SSH_TERMINAL_SMOKE=1 flutter test test/terminal/_ssh_terminal_input_smoke_test.dart
```

SSH 文件队列支持移除等待任务、取消活动传输、重试失败任务，并按会话保存不含凭据的待处理任务描述。重新打开文件页后任务会暂停，检查后需手动点击“恢复任务”；本地路径上传会在恢复前核对文件名、大小和修改时间。来自内存选择器或 macOS 文件承诺的上传源无法跨应用重启恢复，会标记为仅当前运行期间有效。SFTP 上传失败或进程中断后可从隐藏部分文件续传，成功后校验长度并原子替换目标；显式取消会删除部分文件并保留原目标。双栏 SFTP 下载取消后保留隐藏部分文件，可重新排队续传。取消 SCP 上传可能留下不完整的远端目标。

在 Windows 开发环境运行 `flutter run -d windows`，或使用 `flutter build windows --release` 构建。

## 当前终端会话

- Linux 启动 `$SHELL` 指定的 bash/zsh 等 shell；Windows 启动 `ComSpec` 指定的系统 shell，通常是 `cmd.exe`。如果 PowerShell 或其他 shell 已安装并在 PATH 中，可以直接从终端内启动。
- 支持 ANSI 颜色、滚动缓冲、键盘输入、窗口尺寸同步；中文输入走 Flutter 文本输入连接，Linux IBus/Fcitx 候选框跟随终端光标，已组合文本只提交一次；右键或 `Ctrl+Shift+C/V` 可复制选区、粘贴剪贴板文本。分屏广播开启时，粘贴会先确认接收终端。
- `packages/xterm` 保留了 xterm 4.0.0 的本地源码补丁，用于向桌面输入法报告正确的终端光标区域和视图变换。
- 支持多个本地 shell、串口、Telnet 和 SSH 标签；每个标签独立维护终端缓冲和输入状态，可新增、切换、关闭或重新连接会话。
- 终端工作区支持单窗、左右、上下及四窗布局，布局选择保存在本机；下次启动会恢复窗格形状并显示待连接空窗格，不会自动启动 Shell 或连接远端。打开新会话时优先填入空窗格。可手动向可见分屏或勾选的多个标签广播输入，并在标签栏下方显示目标提示。桌面模式创建本地 Shell 填充新窗格，浏览器模式可将现有标签放入窗格。
- 可搜索当前终端及滚屏缓冲区，支持大小写选项、结果高亮以及前后跳转；单次搜索最多显示 2000 个匹配项。
- 命令片段保存在本机，可创建、编辑、删除和粘贴到当前终端；只允许单行，粘贴时不发送 Enter。输入广播开启时会先确认目标会话；片段中不要保存密码或令牌。
- 多会话输入广播可勾选多个已连接标签；开启时标签栏下方显示广播目标，键盘输入（包括 Enter）会同步发送到所选会话。剪贴板、命令片段和远端路径粘贴前会再次确认目标。
- 可为每个标签记录最多 10 MiB 的终端显示输出并保存为日志；关闭含未保存记录的标签时，可选择保存、丢弃或取消。记录可能包含 shell 回显的命令或其他输出内容，请检查后再分享。
- 会话中心采用顶部连接工具栏、最左侧会话/文件切换栏、左侧内容区和右侧终端工作区；会话页提供可搜索、可分类的已保存会话和最近连接，并支持会话备份导入/导出。SSH 文件页跟随当前标签浏览远端目录，并可打开本地/远端双栏管理器；紧凑屏幕以分段按钮切换两侧。
- 设置页支持浅色与深色主题、10–24 px 终端字号及常见等宽字体选择，预览包含中文字符；字体不可用时遵从系统回退，设置保存在本机。
- SSH 会话支持 10、30、60 秒保活间隔或关闭；默认 10 秒，设置仅影响新建立的 SSH 连接。
- 快速连接窗口用于临时连接，成功后进入最近连接；工具栏的串口/Telnet 入口和侧栏“新建会话”打开独立的新建模式，可填写备注名并保存到会话列表。
- 已保存会话以备注名作为醒目的主标题，以设备路径或 IP/端口作为较小的副标题；未填写备注名时使用连接地址作为名称。记录支持重命名、删除或重新打开，最近连接保留最近 20 项。
- 普通会话配置保存在本机偏好设置中，不包含 SSH 用户名和密码。SSH 主机密钥首次连接时须手动确认；已信任主机出现密钥变化时会阻止连接并提示核对。
- 串口连接可枚举设备并支持手动输入端口；设备列表显示“端口名（设备名）”，波特率支持输入任意有效正整数并可从常用预设中选择。默认 115200、8N1、无流控；高级设置提供数据位、校验位、停止位和流控。
- Telnet 支持自定义主机和端口，处理 RFC 854 命令与选项协商、终端类型和 NAWS 窗口尺寸；远端登录提示在终端内交互。
- 快捷键可在“设置 → 终端快捷键”中改绑：`Ctrl+Shift+Q` 打开快速连接，`Ctrl+Shift+T` 新建本地终端，`Ctrl+Shift+C/V` 复制/粘贴，`Ctrl+F` 搜索当前终端输出，`Ctrl+W` 关闭当前终端，`Ctrl+Tab` / `Ctrl+Shift+Tab` 切换标签；macOS 使用 `Command` 替代 `Ctrl`。自定义组合保留 Ctrl/Command，可选 Shift；Alt 和 AltGr 组合继续交给文字输入。
- SSH 支持密码、私钥、Linux/macOS 系统 SSH Agent 和键盘交互式认证；Agent 从 `SSH_AUTH_SOCK` 读取公钥，并在认证时请求签名，不复制或保存 Agent 私钥。Windows OpenSSH Agent 命名管道尚未接入。私钥可粘贴或从文件选择；支持 OpenSSH、PKCS#1 RSA 和 SEC1 EC 私钥及可选私钥口令。认证模式可选“优先密码”“优先密钥”或“自动”；优先模式会在首选认证失败后尝试另一种可用认证，自动模式在有私钥或 Agent 身份时先试密钥，否则先试密码。Agent 身份也用于单层跳板机认证。
- 桌面端会话侧栏可导入 `~/.ssh/config` 或选择其他 OpenSSH 配置文件，预览并勾选 `Host` 别名后加入已保存会话。导入 `HostName`、`User`、`Port` 和第一个 `IdentityFile`；连接时按配置路径读取私钥，不复制私钥内容到导入记录。单个 `ProxyJump` Host 别名会作为一层跳板导入，并沿用该别名的主机、端口、用户名、私钥路径和凭据记录；目标及跳板设置均按首个匹配值解析。未定义别名、自身跳转、多跳、`user@host:port` 写法及 `ProxyCommand` 会阻止对应主机导入并显示提示，避免把代理路由错误地改成直连。`Include` 不展开，`Match` 条件及其中配置会跳过。SSH 连接也可选择一个已保存的直连 SSH 会话作为单层跳板机；跳板机凭据仍存入对应的安全凭据记录，路由信息随会话备份保存，但不包含秘密内容。经跳板连接时，目标主机端口敲门暂不可用。
- SSH 登录进度会显示在顶部会话标签的状态行和底部提示条。后台会话的提示会附带会话名称；收到键盘交互式质询时会弹出输入框并按服务端要求隐藏或显示输入。
- SSH 文件页支持目录导航、创建目录、重命名、删除文件及空目录、修改八进制权限、上传和下载。多文件传输进入会话内 FIFO 队列，逐项执行，显示任务状态和当前文件进度；等待任务可移除，活动传输可取消，失败任务可重试，结束记录可清除。队列按会话保存不含凭据的任务描述；重新打开文件页后需检查并手动恢复。可访问的本地路径上传会检查文件名、大小和修改时间，内存选择器及文件承诺源仅在当前运行期间有效。SFTP 本地路径上传失败或进程中断后会保留隐藏部分文件与源版本信息，重试时核对本地源、从现有偏移续传，完成长度校验后原子重命名；显式取消或源文件变化会清理片段并保留原目标。覆盖要求服务端支持 OpenSSH POSIX rename 扩展。双栏 SFTP 下载取消或中断后保留隐藏部分文件，重新排队同一远端文件到同一目录可续传；远端版本变化会从头开始。未提供修改时间的服务端回退到内存下载；SCP 与传统保存对话框下载缓存于内存，不支持续传。覆盖时保留普通读写执行权限，不复制旧文件所有者、时间戳或扩展 ACL。取消 SCP 上传可能留下不完整远端目标；SCP 模式沿用远端 `scp` 写入行为，需要远端安装并允许执行 `scp`。双击文件可编辑 2 MiB 以内的 UTF-8 文本；保存前检查远端版本，使用同目录临时文件写入后重命名。文件列表默认用 SFTP 浏览；传输协议可选 SFTP 或 SCP。本地文件可拖到远端文件列表或终端区域上传到当前远端目录；从远端文件列表拖到终端会粘贴该文件的绝对路径，不会自动执行命令。
- 活动 SSH 标签可管理本地 `-L`、远程 `-R` 及 SOCKS5 动态 `-D` 隧道；监听默认绑定 `127.0.0.1`，结束 SSH 会话时自动关闭隧道。浏览器版本不支持本机监听隧道。
- SSH 标签可打开 Linux 远程监控：每 5 秒通过固定的只读命令采集负载、内存、根文件系统和进程信息，趋势最多保留最近 2 分钟；无需安装 Agent，Windows 主机暂不支持。
- 桌面与 Android 提供本机网络诊断，可查询单个主机的 DNS 地址或尝试连接单个 TCP 端口；TCP 握手后立即关闭，不发送应用数据，主机和端口不会保存。浏览器端不提供本机网络诊断。
- 桌面和 Android 直接连接 SSH TCP 端口；浏览器需要二进制 WebSocket SSH 网关，HTTPS 页面必须连接 `wss://`。
- SSH 端口输入框旁可配置多条敲门与延迟操作，敲门支持 TCP 连接后关闭、发送一个空 UDP 数据报或发送一次 ICMP Echo Request；操作可拖动排序并随会话记录保存。Web 端由 WebSocket 网关代发，网关需支持 `transport=udp` 和 `transport=icmp` 参数，TCP 使用默认连接方式。
- 浏览器版本目前仅提供 SSH；本地 Shell、串口和 Telnet 依赖浏览器不可用的本机能力。
- 只有勾选“保存登录凭据”后才会记住密码、私钥和私钥口令。Linux/macOS 凭据文件位于 `getApplicationSupportDirectory()/ssh/credentials.json`，目录权限为 `0700`、文件权限为 `0600`；Windows 使用当前用户的应用支持目录。Android 使用 `flutter_secure_storage` 的 Android 加密存储；Web 使用 Web Crypto，并要求 HTTPS 或 localhost。

## 外观与隐私设置

- 新配置默认使用 HexHub 风格浅色主题；设置页也提供翡翠、海洋和石墨三种深色主题，工作区和终端会同步切换配色。
- 可设置主密码锁定应用启动；主密码用于启动解锁，SSH 凭据继续由各平台的凭据存储单独保护。
- Linux、Windows 和 macOS 可选择记住窗口位置和大小。
- “清除应用数据”会关闭活动会话，并删除已保存/最近连接、SSH 主机信任、SSH 登录凭据及主题、窗口和主密码设置。

## 架构约定

- Flutter 负责界面和终端呈现；Rust 负责本地 PTY、串口、Telnet 和本地规则分析。SSH、SFTP 与 SCP 使用 Dart `dartssh2`，复用桌面/Android TCP 与浏览器 WebSocket 传输。
- Dart/Rust 接口由 Flutter Rust Bridge 从 `crates/core/src/api/` 生成，避免手写 FFI 内存管理。
- 终端通过 PTY 字节流连接默认系统 shell；Linux 使用 `$SHELL`，Windows 使用 `ComSpec`（通常是 `cmd.exe`）。
- 本地 PTY、串口和 Telnet 输出按块通过 Rust stream 传给 xterm；SSH 使用相同的标签、输入缓冲和尺寸同步逻辑，通过 `dartssh2` 管理远端 shell。
- 本地 shell 使用当前用户权限；串口连接受操作系统设备权限控制。Flutter 静态分析及 Linux、Android Debug、Web Debug 构建已通过；Android 设备、浏览器 WebSocket 网关和真实 SSH 服务器连接尚未实机验收。
