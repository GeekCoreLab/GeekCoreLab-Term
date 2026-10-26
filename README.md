# Geekcore Term

跨平台终端工作区，采用 Flutter/Dart 界面与 Rust 核心。当前支持本地交互终端、串口和 Telnet 会话，Flutter 使用 xterm 呈现终端数据。SSH、SFTP、监控等能力尚未实现。

## 项目结构

- `lib/`：Flutter 界面
- `crates/core/`：Rust 核心库及 Flutter Rust Bridge API
- `lib/terminal/`：终端视图、会话中心与本地会话记录
- `hook/`：Flutter Native Assets 构建钩子
- `系统设计方案.md`：产品范围、架构和验收目标

## 开发环境

- Flutter 3.44.9 或兼容版本
- Rust 1.98.1（通过 workspace 和核心 crate 的 `rust-toolchain.toml` 固定）
- Linux 桌面开发依赖；Windows 桌面构建需在 Windows/MSVC 环境执行
- `flutter_rust_bridge_codegen` 2.13.0
- Rust `portable-pty` 0.9.0、`serialport` 4.10.1 与 Dart `xterm` 4.0.0

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
- 支持多个本地 shell、串口和 Telnet 标签；每个标签独立维护终端缓冲和输入状态，可新增、切换、关闭或重新连接会话。
- 会话中心采用顶部连接工具栏、左侧会话列表和右侧终端工作区；工具栏排列本地终端、串口和 Telnet 入口，最右侧提供快速连接；左侧提供可搜索的已保存会话和最近连接。
- 快速连接窗口用于临时连接，成功后进入最近连接；工具栏的串口/Telnet 入口和侧栏“新建会话”打开独立的新建模式，可填写备注名并保存到会话列表。
- 已保存会话以备注名作为醒目的主标题，以设备路径或 IP/端口作为较小的副标题；未填写备注名时使用连接地址作为名称。记录支持重命名、删除或重新打开，最近连接保留最近 20 项。
- 会话配置保存在本机偏好设置中，仅包含名称、协议、设备/主机、端口或波特率及串口参数，不保存登录密码。
- 串口连接可枚举设备并支持手动输入端口；设备列表显示“端口名（设备名）”，波特率支持输入任意有效正整数并可从常用预设中选择。默认 115200、8N1、无流控；高级设置提供数据位、校验位、停止位和流控。
- Telnet 支持自定义主机和端口，处理 RFC 854 命令与选项协商、终端类型和 NAWS 窗口尺寸；远端登录提示在终端内交互。
- 快捷键：`Ctrl+Shift+Q` 打开快速连接，`Ctrl+Shift+T` 新建本地终端，`Ctrl+W` 关闭当前终端，`Ctrl+Tab` / `Ctrl+Shift+Tab` 切换标签；macOS 使用 `Command` 替代 `Ctrl`。
- SSH、SFTP 等远程连接尚未实现。

## 架构约定

- Flutter 负责界面和终端呈现；Rust 负责会话、协议、传输、监控和本地规则分析。
- Dart/Rust 接口由 Flutter Rust Bridge 从 `crates/core/src/api/` 生成，避免手写 FFI 内存管理。
- 终端通过 PTY 字节流连接默认系统 shell；Linux 使用 `$SHELL`，Windows 使用 `ComSpec`（通常是 `cmd.exe`）。
- 输出按块通过 Rust stream 传给 xterm；键盘输入按短时间窗口合批写入 PTY，窗口尺寸变化同步到 shell。
- 本地 shell 使用当前用户权限；串口连接受操作系统设备权限控制。当前 Linux Debug 构建已通过；Windows 构建、串口硬件和 Telnet 服务端实连验收待完成。
