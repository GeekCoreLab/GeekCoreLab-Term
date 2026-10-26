use crate::frb_generated::StreamSink;
use crate::telnet::{self, TelnetParser};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serialport::SerialPort;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

struct TerminalSession {
    reader: Mutex<Option<Box<dyn Read + Send>>>,
    writer: Mutex<Box<dyn Write + Send>>,
    backend: SessionBackend,
    closed: AtomicBool,
}

enum SessionBackend {
    Local {
        master: Mutex<Box<dyn MasterPty + Send>>,
        child: Mutex<Box<dyn portable_pty::Child + Send + Sync>>,
    },
    Serial,
    Telnet {
        stream: TcpStream,
        naws_enabled: AtomicBool,
        binary_input: AtomicBool,
        binary_output: AtomicBool,
        dimensions: Mutex<(u16, u16)>,
    },
}

struct SerialReader(Box<dyn SerialPort>);

impl Read for SerialReader {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.0.read(buffer)
    }
}

struct SerialWriter(Box<dyn SerialPort>);

impl Write for SerialWriter {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        self.0.write(buffer)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()
    }
}

static NEXT_SESSION_ID: AtomicI64 = AtomicI64::new(1);
static SESSIONS: OnceLock<Mutex<HashMap<i64, Arc<TerminalSession>>>> = OnceLock::new();

fn sessions() -> &'static Mutex<HashMap<i64, Arc<TerminalSession>>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn get_session(session_id: i64) -> Result<Arc<TerminalSession>, String> {
    sessions()
        .lock()
        .map_err(|_| "终端会话锁已损坏".to_owned())?
        .get(&session_id)
        .cloned()
        .ok_or_else(|| "终端会话不存在或已关闭".to_owned())
}

fn register_session(
    reader: Box<dyn Read + Send>,
    writer: Box<dyn Write + Send>,
    backend: SessionBackend,
) -> Result<i64, String> {
    let session_id = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    let session = Arc::new(TerminalSession {
        reader: Mutex::new(Some(reader)),
        writer: Mutex::new(writer),
        backend,
        closed: AtomicBool::new(false),
    });
    sessions()
        .lock()
        .map_err(|_| "终端会话锁已损坏".to_owned())?
        .insert(session_id, session);
    Ok(session_id)
}

pub fn start_local_shell(cols: i32, rows: i32) -> Result<i64, String> {
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows: rows.clamp(1, 500) as u16,
            cols: cols.clamp(1, 1000) as u16,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| format!("无法创建本地终端: {error}"))?;

    let mut command = CommandBuilder::new_default_prog();
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");

    #[cfg(windows)]
    let home = std::env::var_os("USERPROFILE");
    #[cfg(unix)]
    let home = std::env::var_os("HOME");
    if let Some(home) = home {
        command.cwd(home);
    }

    let child = pair
        .slave
        .spawn_command(command)
        .map_err(|error| format!("无法启动系统 shell: {error}"))?;
    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|error| format!("无法读取终端输出: {error}"))?;
    let writer = pair
        .master
        .take_writer()
        .map_err(|error| format!("无法写入终端输入: {error}"))?;

    register_session(
        reader,
        writer,
        SessionBackend::Local {
            master: Mutex::new(pair.master),
            child: Mutex::new(child),
        },
    )
}

#[derive(Debug, Clone)]
pub struct SerialPortEntry {
    pub port_name: String,
    pub device_name: String,
}

pub fn list_serial_ports() -> Result<Vec<SerialPortEntry>, String> {
    let mut ports = serialport::available_ports()
        .map_err(|error| format!("无法枚举串口: {error}"))?
        .into_iter()
        .map(|port| {
            let device_name = match port.port_type {
                serialport::SerialPortType::UsbPort(info) => {
                    let manufacturer = info.manufacturer.filter(|value| !value.trim().is_empty());
                    let product = info.product.filter(|value| !value.trim().is_empty());
                    match (manufacturer, product) {
                        (Some(manufacturer), Some(product))
                            if !product.eq_ignore_ascii_case(&manufacturer) =>
                        {
                            format!("{manufacturer} {product}")
                        }
                        (_, Some(product)) => product,
                        (Some(manufacturer), None) => manufacturer,
                        (None, None) => format!("USB {:04X}:{:04X}", info.vid, info.pid),
                    }
                }
                serialport::SerialPortType::PciPort => "PCI 串口设备".to_owned(),
                serialport::SerialPortType::BluetoothPort => "蓝牙串口设备".to_owned(),
                serialport::SerialPortType::Unknown => "未知设备".to_owned(),
            };
            SerialPortEntry {
                port_name: port.port_name,
                device_name,
            }
        })
        .collect::<Vec<_>>();
    ports.sort_by(|left, right| left.port_name.cmp(&right.port_name));
    Ok(ports)
}

pub fn start_serial_session(
    port_name: String,
    baud_rate: u32,
    data_bits: u8,
    parity: String,
    stop_bits: u8,
    flow_control: String,
) -> Result<i64, String> {
    if baud_rate == 0 {
        return Err("波特率必须大于 0".to_owned());
    }

    let data_bits = match data_bits {
        5 => serialport::DataBits::Five,
        6 => serialport::DataBits::Six,
        7 => serialport::DataBits::Seven,
        8 => serialport::DataBits::Eight,
        _ => return Err("数据位必须为 5、6、7 或 8".to_owned()),
    };
    let parity = match parity.as_str() {
        "none" => serialport::Parity::None,
        "odd" => serialport::Parity::Odd,
        "even" => serialport::Parity::Even,
        _ => return Err("校验位只能为 none、odd 或 even".to_owned()),
    };
    let stop_bits = match stop_bits {
        1 => serialport::StopBits::One,
        2 => serialport::StopBits::Two,
        _ => return Err("停止位必须为 1 或 2".to_owned()),
    };
    let flow_control = match flow_control.as_str() {
        "none" => serialport::FlowControl::None,
        "software" => serialport::FlowControl::Software,
        "hardware" => serialport::FlowControl::Hardware,
        _ => return Err("流控只能为 none、software 或 hardware".to_owned()),
    };

    let port = serialport::new(&port_name, baud_rate)
        .data_bits(data_bits)
        .parity(parity)
        .stop_bits(stop_bits)
        .flow_control(flow_control)
        .timeout(Duration::from_millis(200))
        .open()
        .map_err(|error| format!("无法打开串口 {port_name}: {error}"))?;
    let reader = port
        .try_clone()
        .map_err(|error| format!("无法创建串口读取流: {error}"))?;

    register_session(
        Box::new(SerialReader(reader)),
        Box::new(SerialWriter(port)),
        SessionBackend::Serial,
    )
}

pub fn start_telnet_session(host: String, port: u16, cols: i32, rows: i32) -> Result<i64, String> {
    let host = host.trim();
    if host.is_empty() {
        return Err("主机名不能为空".to_owned());
    }

    let addresses = (host, port)
        .to_socket_addrs()
        .map_err(|error| format!("无法解析 Telnet 主机 {host}: {error}"))?;
    let mut last_error = None;
    let mut connected = None;
    for address in addresses {
        match TcpStream::connect_timeout(&address, Duration::from_secs(5)) {
            Ok(stream) => {
                connected = Some(stream);
                break;
            }
            Err(error) => last_error = Some(error),
        }
    }
    let stream = connected.ok_or_else(|| match last_error {
        Some(error) => format!("无法连接 Telnet {host}:{port}: {error}"),
        None => format!("主机 {host} 没有可用的网络地址"),
    })?;
    stream
        .set_nodelay(true)
        .map_err(|error| format!("无法配置 Telnet 连接: {error}"))?;
    stream
        .set_read_timeout(Some(Duration::from_millis(200)))
        .map_err(|error| format!("无法配置 Telnet 读取超时: {error}"))?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| format!("无法配置 Telnet 写入超时: {error}"))?;

    let reader = stream
        .try_clone()
        .map_err(|error| format!("无法创建 Telnet 读取流: {error}"))?;
    let writer = stream
        .try_clone()
        .map_err(|error| format!("无法创建 Telnet 写入流: {error}"))?;
    let cols = cols.clamp(1, 1000) as u16;
    let rows = rows.clamp(1, 500) as u16;
    let mut writer = writer;
    writer
        .write_all(&telnet::initial_negotiation())
        .and_then(|()| writer.flush())
        .map_err(|error| format!("无法开始 Telnet 协商: {error}"))?;

    register_session(
        Box::new(reader),
        Box::new(writer),
        SessionBackend::Telnet {
            stream,
            naws_enabled: AtomicBool::new(false),
            binary_input: AtomicBool::new(false),
            binary_output: AtomicBool::new(false),
            dimensions: Mutex::new((cols, rows)),
        },
    )
}

pub fn read_terminal_output(session_id: i64, sink: StreamSink<Vec<u8>>) {
    let session = match get_session(session_id) {
        Ok(session) => session,
        Err(error) => {
            let _ = sink.add_error(error);
            return;
        }
    };

    let reader = match session.reader.lock() {
        Ok(mut reader) => reader.take(),
        Err(_) => {
            let _ = sink.add_error("终端输出读取锁已损坏".to_owned());
            return;
        }
    };
    let Some(mut reader) = reader else {
        let _ = sink.add_error("终端输出流已经启动".to_owned());
        return;
    };

    let mut telnet_parser = if matches!(&session.backend, SessionBackend::Telnet { .. }) {
        Some(TelnetParser::new())
    } else {
        None
    };
    let mut buffer = [0_u8; 8192];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => {
                if let Some(parser) = &mut telnet_parser {
                    let trailing = parser.finish();
                    if !trailing.is_empty() && sink.add(trailing).is_err() {
                        break;
                    }
                }
                break;
            }
            Ok(length) => {
                let output = if let Some(parser) = &mut telnet_parser {
                    let (cols, rows) = match &session.backend {
                        SessionBackend::Telnet { dimensions, .. } => {
                            dimensions.lock().map(|value| *value).unwrap_or((80, 24))
                        }
                        _ => (80, 24),
                    };
                    let frame = parser.process(&buffer[..length], cols, rows);
                    if !frame.replies.is_empty() {
                        match write_session_bytes(&session, &frame.replies) {
                            Ok(()) => {}
                            Err(error) => {
                                if !session.closed.load(Ordering::Acquire) {
                                    let _ = sink.add_error(format!("Telnet 协商写入失败: {error}"));
                                }
                                break;
                            }
                        }
                    }
                    if let SessionBackend::Telnet {
                        naws_enabled,
                        binary_input,
                        binary_output,
                        ..
                    } = &session.backend
                    {
                        naws_enabled.store(frame.naws_enabled, Ordering::Release);
                        binary_input.store(frame.remote_binary, Ordering::Release);
                        binary_output.store(frame.local_binary, Ordering::Release);
                    }
                    frame.data
                } else {
                    buffer[..length].to_vec()
                };
                if !output.is_empty() && sink.add(output).is_err() {
                    break;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::Interrupted
                        | std::io::ErrorKind::TimedOut
                        | std::io::ErrorKind::WouldBlock
                ) =>
            {
                if session.closed.load(Ordering::Acquire) {
                    break;
                }
            }
            Err(error) => {
                if !session.closed.load(Ordering::Acquire) {
                    let _ = sink.add_error(format!("读取终端输出失败: {error}"));
                }
                break;
            }
        }
    }
}

pub fn write_terminal_input(session_id: i64, data: Vec<u8>) -> Result<(), String> {
    let session = get_session(session_id)?;
    let outgoing = match &session.backend {
        SessionBackend::Telnet { binary_output, .. } => {
            telnet::encode_terminal_input(&data, binary_output.load(Ordering::Acquire))
        }
        _ => data,
    };
    write_session_bytes(&session, &outgoing).map_err(|error| format!("写入终端输入失败: {error}"))
}

fn write_session_bytes(session: &TerminalSession, data: &[u8]) -> std::io::Result<()> {
    let mut writer = session
        .writer
        .lock()
        .map_err(|_| std::io::Error::other("终端输入锁已损坏"))?;
    writer.write_all(data).and_then(|()| writer.flush())
}

pub fn resize_terminal_session(session_id: i64, cols: i32, rows: i32) -> Result<(), String> {
    let session = get_session(session_id)?;
    match &session.backend {
        SessionBackend::Local { master, .. } => {
            let master = master.lock().map_err(|_| "终端尺寸锁已损坏".to_owned())?;
            master
                .resize(PtySize {
                    rows: rows.clamp(1, 500) as u16,
                    cols: cols.clamp(1, 1000) as u16,
                    pixel_width: 0,
                    pixel_height: 0,
                })
                .map_err(|error| format!("调整终端尺寸失败: {error}"))
        }
        SessionBackend::Telnet {
            naws_enabled,
            dimensions,
            ..
        } => {
            let size = (cols.clamp(1, 1000) as u16, rows.clamp(1, 500) as u16);
            *dimensions
                .lock()
                .map_err(|_| "Telnet 窗口尺寸锁已损坏".to_owned())? = size;
            if naws_enabled.load(Ordering::Acquire) {
                write_session_bytes(&session, &telnet::naws_packet(size.0, size.1))
                    .map_err(|error| format!("发送 Telnet 窗口尺寸失败: {error}"))?;
            }
            Ok(())
        }
        SessionBackend::Serial => Ok(()),
    }
}

pub fn close_terminal_session(session_id: i64) -> Result<(), String> {
    let session = sessions()
        .lock()
        .map_err(|_| "终端会话锁已损坏".to_owned())?
        .remove(&session_id);
    let Some(session) = session else {
        return Ok(());
    };
    session.closed.store(true, Ordering::Release);

    match &session.backend {
        SessionBackend::Local { child, .. } => {
            let mut child = child.lock().map_err(|_| "终端进程锁已损坏".to_owned())?;
            let _ = child.kill();
            let _ = child.wait();
        }
        SessionBackend::Telnet { stream, .. } => {
            let _ = stream.shutdown(Shutdown::Both);
        }
        SessionBackend::Serial => {}
    }
    Ok(())
}
