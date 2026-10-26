# Geekcore Term

跨平台终端工作区，采用 Flutter/Dart 界面与 Rust 核心。当前支持本地交互终端、串口、Telnet 和 SSH 密码/私钥认证终端，SSH 支持认证模式选择、交互式质询和按序 TCP/UDP/ICMP 端口敲门，Flutter 使用 xterm 呈现终端数据。SFTP、SSH Agent 和监控等能力尚未实现。

## 项目结构

- `lib/`：Flutter 界面
- `crates/core/`：Rust 核心库及 Flutter Rust Bridge API
- `lib/terminal/`：终端视图、会话中心与本地会话记录
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

在 Windows 开发环境运行 `flutter run -d windows`，或使用 `flutter build windows --release` 构建。

## 当前终端会话

- Linux 启动 `$SHELL` 指定的 bash/zsh 等 shell；Windows 启动 `ComSpec` 指定的系统 shell，通常是 `cmd.exe`。如果 PowerShell 或其他 shell 已安装并在 PATH 中，可以直接从终端内启动。
- 支持 ANSI 颜色、滚动缓冲、键盘输入、窗口尺寸同步；中文输入走 Flutter 文本输入连接，Linux IBus/Fcitx 候选框跟随终端光标，已组合文本只提交一次；右键可复制选区或粘贴剪贴板文本。
- `packages/xterm` 保留了 xterm 4.0.0 的本地源码补丁，用于向桌面输入法报告正确的终端光标区域和视图变换。
- 支持多个本地 shell、串口、Telnet 和 SSH 标签；每个标签独立维护终端缓冲和输入状态，可新增、切换、关闭或重新连接会话。
- 会话中心采用顶部连接工具栏、左侧会话列表和右侧终端工作区；工具栏提供本地终端、串口、Telnet 和 SSH 入口，最右侧提供快速连接；左侧提供可搜索的已保存会话和最近连接。
- 快速连接窗口用于临时连接，成功后进入最近连接；工具栏的串口/Telnet 入口和侧栏“新建会话”打开独立的新建模式，可填写备注名并保存到会话列表。
- 已保存会话以备注名作为醒目的主标题，以设备路径或 IP/端口作为较小的副标题；未填写备注名时使用连接地址作为名称。记录支持重命名、删除或重新打开，最近连接保留最近 20 项。
- 普通会话配置保存在本机偏好设置中，不包含 SSH 用户名和密码。SSH 主机密钥首次连接时须手动确认；已信任主机出现密钥变化时会阻止连接并提示核对。
- 串口连接可枚举设备并支持手动输入端口；设备列表显示“端口名（设备名）”，波特率支持输入任意有效正整数并可从常用预设中选择。默认 115200、8N1、无流控；高级设置提供数据位、校验位、停止位和流控。
- Telnet 支持自定义主机和端口，处理 RFC 854 命令与选项协商、终端类型和 NAWS 窗口尺寸；远端登录提示在终端内交互。
- 快捷键：`Ctrl+Shift+Q` 打开快速连接，`Ctrl+Shift+T` 新建本地终端，`Ctrl+W` 关闭当前终端，`Ctrl+Tab` / `Ctrl+Shift+Tab` 切换标签；macOS 使用 `Command` 替代 `Ctrl`。
- SSH 支持密码、私钥和键盘交互式认证，私钥可粘贴或从文件选择；支持 OpenSSH、PKCS#1 RSA 和 SEC1 EC 私钥及可选私钥口令。认证模式可选“优先密码”“优先密钥”或“自动”；优先模式会在首选认证失败后尝试另一种可用认证，自动模式在有私钥时先试密钥，否则先试密码。
- SSH 登录进度会显示在顶部会话标签的状态行和底部提示条。后台会话的提示会附带会话名称；收到键盘交互式质询时会弹出输入框并按服务端要求隐藏或显示输入。
- 桌面和 Android 直接连接 SSH TCP 端口；浏览器需要二进制 WebSocket SSH 网关，HTTPS 页面必须连接 `wss://`。
- SSH 端口输入框旁可配置多条敲门与延迟操作，敲门支持 TCP 连接后关闭、发送一个空 UDP 数据报或发送一次 ICMP Echo Request；操作可拖动排序并随会话记录保存。Web 端由 WebSocket 网关代发，网关需支持 `transport=udp` 和 `transport=icmp` 参数，TCP 使用默认连接方式。
- 浏览器版本目前仅提供 SSH；本地 Shell、串口和 Telnet 依赖浏览器不可用的本机能力。
- 只有勾选“保存登录凭据”后才会记住密码、私钥和私钥口令。Linux/macOS 凭据文件位于 `getApplicationSupportDirectory()/ssh/credentials.json`，目录权限为 `0700`、文件权限为 `0600`；Windows 使用当前用户的应用支持目录。Android 使用 `flutter_secure_storage` 的 Android 加密存储；Web 使用 Web Crypto，并要求 HTTPS 或 localhost。

## 外观与隐私设置

- 设置页提供翡翠、海洋和石墨三种深色主题，工作区和终端会同步切换配色。
- 可设置主密码锁定应用启动；主密码用于启动解锁，SSH 凭据继续由各平台的凭据存储单独保护。
- Linux、Windows 和 macOS 可选择记住窗口位置和大小。
- “清除应用数据”会关闭活动会话，并删除已保存/最近连接、SSH 主机信任、SSH 登录凭据及主题、窗口和主密码设置。

## 架构约定

- Flutter 负责界面和终端呈现；Rust 负责本地 PTY、串口、Telnet 和本地规则分析。SSH 使用 Dart `dartssh2` 以复用桌面/Android TCP 与浏览器 WebSocket 传输。
- Dart/Rust 接口由 Flutter Rust Bridge 从 `crates/core/src/api/` 生成，避免手写 FFI 内存管理。
- 终端通过 PTY 字节流连接默认系统 shell；Linux 使用 `$SHELL`，Windows 使用 `ComSpec`（通常是 `cmd.exe`）。
- 本地 PTY、串口和 Telnet 输出按块通过 Rust stream 传给 xterm；SSH 使用相同的标签、输入缓冲和尺寸同步逻辑，通过 `dartssh2` 管理远端 shell。
- 本地 shell 使用当前用户权限；串口连接受操作系统设备权限控制。Flutter 静态分析及 Linux、Android Debug、Web Debug 构建已通过；Android 设备、浏览器 WebSocket 网关和真实 SSH 服务器连接尚未实机验收。
