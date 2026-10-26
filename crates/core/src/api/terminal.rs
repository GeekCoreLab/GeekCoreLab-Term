use crate::frb_generated::StreamSink;
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

struct LocalShell {
    master: Mutex<Box<dyn MasterPty + Send>>,
    reader: Mutex<Option<Box<dyn Read + Send>>>,
    writer: Mutex<Box<dyn Write + Send>>,
    child: Mutex<Box<dyn portable_pty::Child + Send + Sync>>,
}

static NEXT_SESSION_ID: AtomicI64 = AtomicI64::new(1);
static SESSIONS: OnceLock<Mutex<HashMap<i64, Arc<LocalShell>>>> = OnceLock::new();

fn sessions() -> &'static Mutex<HashMap<i64, Arc<LocalShell>>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn get_session(session_id: i64) -> Result<Arc<LocalShell>, String> {
    sessions()
        .lock()
        .map_err(|_| "终端会话锁已损坏".to_owned())?
        .get(&session_id)
        .cloned()
        .ok_or_else(|| "终端会话不存在或已关闭".to_owned())
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

    let session_id = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    let session = Arc::new(LocalShell {
        master: Mutex::new(pair.master),
        reader: Mutex::new(Some(reader)),
        writer: Mutex::new(writer),
        child: Mutex::new(child),
    });

    sessions()
        .lock()
        .map_err(|_| "终端会话锁已损坏".to_owned())?
        .insert(session_id, session);

    Ok(session_id)
}

pub fn read_local_shell_output(session_id: i64, sink: StreamSink<Vec<u8>>) {
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

    let mut buffer = [0_u8; 8192];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(length) => {
                if sink.add(buffer[..length].to_vec()).is_err() {
                    break;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => {
                let _ = sink.add_error(format!("读取终端输出失败: {error}"));
                break;
            }
        }
    }
}

pub fn write_local_shell_input(session_id: i64, data: Vec<u8>) -> Result<(), String> {
    let session = get_session(session_id)?;
    let mut writer = session
        .writer
        .lock()
        .map_err(|_| "终端输入锁已损坏".to_owned())?;
    writer
        .write_all(&data)
        .and_then(|()| writer.flush())
        .map_err(|error| format!("写入终端输入失败: {error}"))
}

pub fn resize_local_shell(session_id: i64, cols: i32, rows: i32) -> Result<(), String> {
    let session = get_session(session_id)?;
    let master = session
        .master
        .lock()
        .map_err(|_| "终端尺寸锁已损坏".to_owned())?;
    master
        .resize(PtySize {
            rows: rows.clamp(1, 500) as u16,
            cols: cols.clamp(1, 1000) as u16,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| format!("调整终端尺寸失败: {error}"))
}

pub fn close_local_shell(session_id: i64) -> Result<(), String> {
    let session = sessions()
        .lock()
        .map_err(|_| "终端会话锁已损坏".to_owned())?
        .remove(&session_id);
    let Some(session) = session else {
        return Ok(());
    };

    let mut child = session
        .child
        .lock()
        .map_err(|_| "终端进程锁已损坏".to_owned())?;
    let _ = child.kill();
    let _ = child.wait();
    Ok(())
}
