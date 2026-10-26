# Geekcore Term

跨平台终端工作区，采用 Flutter/Dart 界面与 Rust 核心。当前已实现基础本地交互终端：Rust 创建系统 PTY 并启动默认 shell，Flutter 使用 xterm 呈现 ANSI 终端。SSH、SFTP、监控等能力尚未实现。

## 项目结构

- `lib/`：Flutter 界面
- `crates/core/`：Rust 核心库及 Flutter Rust Bridge API
- `lib/terminal/`：本地终端视图、键盘输入与会话生命周期
- `hook/`：Flutter Native Assets 构建钩子
- `系统设计方案.md`：产品范围、架构和验收目标

## 开发环境

- Flutter 3.44.9 或兼容版本
- Rust 1.98.1（通过 workspace 和核心 crate 的 `rust-toolchain.toml` 固定）
- Linux 桌面开发依赖；Windows 桌面构建需在 Windows/MSVC 环境执行
- `flutter_rust_bridge_codegen` 2.13.0
- Rust `portable-pty` 0.9.0 与 Dart `xterm` 4.0.0

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

## 当前本地终端

- Linux 启动 `$SHELL` 指定的 bash/zsh 等 shell；Windows 启动 `ComSpec` 指定的系统 shell，通常是 `cmd.exe`。如果 PowerShell 或其他 shell 已安装并在 PATH 中，可以直接从终端内启动。
- 支持 ANSI 颜色、滚动缓冲、键盘输入、窗口尺寸同步；中文输入走 Flutter 文本输入连接，Linux IBus/Fcitx 候选框跟随终端光标，已组合文本只提交一次；右键可复制选区或粘贴剪贴板文本。
- `packages/xterm` 保留了 xterm 4.0.0 的本地源码补丁，用于向桌面输入法报告正确的终端光标区域和视图变换。
- 支持同时打开多个本地 shell 标签；每个标签独立维护 PTY 进程、终端缓冲和输入状态，可新增、切换、关闭或重启会话。
- 快捷键：`Ctrl+Shift+T` 新建终端，`Ctrl+W` 关闭当前终端，`Ctrl+Tab` / `Ctrl+Shift+Tab` 切换标签；macOS 使用 `Command` 替代 `Ctrl`。
- 当前仅支持本地 shell 会话；SSH、SFTP 等远程连接尚未实现。

## 架构约定

- Flutter 负责界面和终端呈现；Rust 负责会话、协议、传输、监控和本地规则分析。
- Dart/Rust 接口由 Flutter Rust Bridge 从 `crates/core/src/api/` 生成，避免手写 FFI 内存管理。
- 终端通过 PTY 字节流连接默认系统 shell；Linux 使用 `$SHELL`，Windows 使用 `ComSpec`（通常是 `cmd.exe`）。
- 输出按块通过 Rust stream 传给 xterm；键盘输入按短时间窗口合批写入 PTY，窗口尺寸变化同步到 shell。
- 本地 shell 使用当前用户权限。跨平台构建已生成，当前 Linux Debug 构建通过；Windows 运行仍需在 Windows 环境验收。
