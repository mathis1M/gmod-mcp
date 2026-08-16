use std::{
    collections::{HashMap, VecDeque},
    io::{self, BufRead, Write},
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, Sender},
        Arc, Mutex, OnceLock,
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use gmod::{gmod13_close, gmod13_open, lua::State, lua_string};
use serde::{Deserialize, Serialize};

const BIND_ADDRESS: &str = "127.0.0.1:17905";
const STATUS_REQUEST: &str = r#"{"action":"status"}"#;
const EXEC_LUA_CODE_ACTION: &str = "exec_lua_code";
const PLAYERS_ACTION: &str = "gmod_players";
const ENTITIES_ACTION: &str = "gmod_entities";
const SCREENSHOT_ACTION: &str = "screenshot";
const MAX_LUA_CODE_BYTES: usize = 60 * 1024;
const MAX_TARGET_BYTES: usize = 256;
const MAX_ENTITY_LIMIT: u32 = 200;
const MAX_SCREENSHOT_BYTES: usize = 1024 * 1024;
const SCREENSHOT_TIMEOUT: Duration = Duration::from_secs(10);
const EXEC_RESULT_TIMEOUT: Duration = Duration::from_secs(10);
const DEFAULT_MESSAGE: &str = "Garry's Mod is unavailable.";

struct Status {
    connected: bool,
    message: String,
}

struct LuaCommand {
    tool: String,
    state: String,
    code: String,
    target: Option<String>,
    class_filter: Option<String>,
    custom_check: Option<String>,
    limit: Option<u32>,
    request_id: Option<String>,
    return_result: bool,
}

#[derive(Deserialize)]
struct BridgeRequest {
    action: String,
    state: Option<String>,
    code: Option<String>,
    target: Option<String>,
    class_filter: Option<String>,
    custom_check: Option<String>,
    limit: Option<u32>,
    return_result: Option<bool>,
}

#[derive(Serialize)]
struct CommandResponse<'a> {
    ok: bool,
    message: &'a str,
}

#[derive(Serialize)]
struct ScreenshotResponse {
    ok: bool,
    format: &'static str,
    size: usize,
}

static STATUS: OnceLock<Mutex<Status>> = OnceLock::new();
static COMMANDS: OnceLock<Mutex<VecDeque<LuaCommand>>> = OnceLock::new();
static SCREENSHOTS: OnceLock<Mutex<HashMap<String, Sender<Result<Vec<u8>, String>>>>> =
    OnceLock::new();
static EXEC_RESULTS: OnceLock<Mutex<HashMap<String, Sender<Result<String, String>>>>> =
    OnceLock::new();
static NEXT_SCREENSHOT_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_EXEC_ID: AtomicU64 = AtomicU64::new(1);

struct Bridge {
    stop: Arc<AtomicBool>,
    thread: JoinHandle<()>,
}

static BRIDGE: OnceLock<Mutex<Option<Bridge>>> = OnceLock::new();

#[gmod13_open]
fn gmod13_open(lua: State) -> i32 {
    clear_commands();
    fail_pending_screenshots(DEFAULT_MESSAGE);
    fail_pending_exec_results(DEFAULT_MESSAGE);
    unsafe { register_lua_api(lua) };
    if let Err(error) = start_bridge() {
        eprintln!("[gmod-mcp] failed to start bridge: {error}");
    }
    0
}

#[gmod13_close]
fn gmod13_close(lua: State) -> i32 {
    let _ = lua;
    stop_bridge();
    clear_commands();
    fail_pending_screenshots(DEFAULT_MESSAGE);
    fail_pending_exec_results(DEFAULT_MESSAGE);
    0
}

fn bridge_state() -> &'static Mutex<Option<Bridge>> {
    BRIDGE.get_or_init(|| Mutex::new(None))
}

fn status_state() -> &'static Mutex<Status> {
    STATUS.get_or_init(|| {
        Mutex::new(Status {
            connected: false,
            message: DEFAULT_MESSAGE.to_owned(),
        })
    })
}

fn command_state() -> &'static Mutex<VecDeque<LuaCommand>> {
    COMMANDS.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn screenshot_state() -> &'static Mutex<HashMap<String, Sender<Result<Vec<u8>, String>>>> {
    SCREENSHOTS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn exec_result_state() -> &'static Mutex<HashMap<String, Sender<Result<String, String>>>> {
    EXEC_RESULTS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[gmod::lua_function]
unsafe fn lua_set_status(lua: State) -> i32 {
    let connected = lua.check_boolean(1);
    let message = lua.check_string(2).into_owned();
    update_status(connected, message);
    0
}

#[gmod::lua_function]
unsafe fn lua_shutdown(lua: State) -> i32 {
    let _ = lua;
    stop_bridge();
    clear_commands();
    fail_pending_screenshots(DEFAULT_MESSAGE);
    fail_pending_exec_results(DEFAULT_MESSAGE);
    0
}

#[gmod::lua_function]
unsafe fn lua_respond_screenshot(lua: State) -> i32 {
    let request_id = lua.check_string(1).into_owned();
    let result = if lua.check_boolean(2) {
        let data = lua.check_binary_string(3).to_vec();
        if data.is_empty() {
            Err("Screenshot is empty.".to_owned())
        } else if data.len() > MAX_SCREENSHOT_BYTES {
            Err(format!(
                "Screenshot exceeds the {} byte limit.",
                MAX_SCREENSHOT_BYTES
            ))
        } else {
            Ok(data)
        }
    } else {
        Err(lua.check_string(3).into_owned())
    };
    complete_screenshot(request_id, result);
    0
}

#[gmod::lua_function]
unsafe fn lua_respond_lua(lua: State) -> i32 {
    let request_id = lua.check_string(1).into_owned();
    let result = if lua.check_boolean(2) {
        Ok(lua.check_string(3).into_owned())
    } else {
        Err(lua.check_string(3).into_owned())
    };
    complete_exec_result(request_id, result);
    0
}

#[gmod::lua_function]
unsafe fn lua_poll_command(lua: State) -> i32 {
    let command = command_state()
        .lock()
        .ok()
        .and_then(|mut commands| commands.pop_front());

    match command {
        Some(command) => {
            lua.new_table();

            lua.push_string(&command.tool);
            lua.set_field(-2, lua_string!("tool"));
            lua.push_string(&command.state);
            lua.set_field(-2, lua_string!("state"));
            lua.push_string(&command.code);
            lua.set_field(-2, lua_string!("code"));
            match command.target {
                Some(target) => lua.push_string(&target),
                None => lua.push_nil(),
            }
            lua.set_field(-2, lua_string!("target"));
            match command.class_filter {
                Some(class_filter) => lua.push_string(&class_filter),
                None => lua.push_nil(),
            }
            lua.set_field(-2, lua_string!("class_filter"));
            match command.custom_check {
                Some(custom_check) => lua.push_string(&custom_check),
                None => lua.push_nil(),
            }
            lua.set_field(-2, lua_string!("custom_check"));
            match command.limit {
                Some(limit) => lua.push_number(limit as f64),
                None => lua.push_nil(),
            }
            lua.set_field(-2, lua_string!("limit"));
            match command.request_id {
                Some(request_id) => lua.push_string(&request_id),
                None => lua.push_nil(),
            }
            lua.set_field(-2, lua_string!("request_id"));
        }
        None => lua.push_nil(),
    }
    1
}

unsafe fn register_lua_api(lua: State) {
    lua.new_table();
    lua.push_function(lua_set_status);
    lua.set_field(-2, lua_string!("set_status"));
    lua.push_function(lua_shutdown);
    lua.set_field(-2, lua_string!("shutdown"));
    lua.push_function(lua_poll_command);
    lua.set_field(-2, lua_string!("poll_command"));
    lua.push_function(lua_respond_screenshot);
    lua.set_field(-2, lua_string!("respond_screenshot"));
    lua.push_function(lua_respond_lua);
    lua.set_field(-2, lua_string!("respond_lua"));
    lua.set_global(lua_string!("gmod_mcp_bridge"));
}

fn update_status(connected: bool, message: String) {
    if let Ok(mut status) = status_state().lock() {
        status.connected = connected;
        status.message = message;
    }
}

fn queue_command(command: LuaCommand) {
    if let Ok(mut commands) = command_state().lock() {
        commands.push_back(command);
    }
}

fn clear_commands() {
    if let Ok(mut commands) = command_state().lock() {
        commands.clear();
    }
}

fn complete_screenshot(request_id: String, result: Result<Vec<u8>, String>) {
    let sender = screenshot_state()
        .lock()
        .ok()
        .and_then(|mut screenshots| screenshots.remove(&request_id));
    if let Some(sender) = sender {
        let _ = sender.send(result);
    }
}

fn complete_exec_result(request_id: String, result: Result<String, String>) {
    let sender = exec_result_state()
        .lock()
        .ok()
        .and_then(|mut results| results.remove(&request_id));
    if let Some(sender) = sender {
        let _ = sender.send(result);
    }
}

fn remove_screenshot(request_id: &str) {
    if let Ok(mut screenshots) = screenshot_state().lock() {
        screenshots.remove(request_id);
    }
}

fn remove_exec_result(request_id: &str) {
    if let Ok(mut results) = exec_result_state().lock() {
        results.remove(request_id);
    }
}

fn fail_pending_screenshots(message: &str) {
    if let Ok(mut screenshots) = screenshot_state().lock() {
        for (_, sender) in screenshots.drain() {
            let _ = sender.send(Err(message.to_owned()));
        }
    }
}

fn fail_pending_exec_results(message: &str) {
    if let Ok(mut results) = exec_result_state().lock() {
        for (_, sender) in results.drain() {
            let _ = sender.send(Err(message.to_owned()));
        }
    }
}

fn status_json() -> String {
    let status = status_state().lock().expect("status lock poisoned");
    format!(
        r#"{{"connected":{},"message":"{}"}}"#,
        status.connected,
        json_escape(&status.message)
    )
}

fn json_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if character.is_control() => {
                escaped.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => escaped.push(character),
        }
    }
    escaped
}

fn command_response(ok: bool, message: &str) -> String {
    serde_json::to_string(&CommandResponse { ok, message })
        .expect("command response should serialize")
}

fn parse_exec_command(request: BridgeRequest) -> Result<LuaCommand, String> {
    let state = request
        .state
        .ok_or_else(|| "state must be 'server' or 'client'.".to_owned())?;
    let code = request
        .code
        .ok_or_else(|| "code must not be missing.".to_owned())?;

    if code.trim().is_empty() {
        return Err("Lua code must not be empty.".to_owned());
    }
    if code.len() > MAX_LUA_CODE_BYTES {
        return Err(format!(
            "Lua code exceeds the {} byte limit.",
            MAX_LUA_CODE_BYTES
        ));
    }

    let return_result = request.return_result.unwrap_or(false);

    match state.as_str() {
        "server" => {
            if request.target.is_some() {
                return Err("target is only valid for client execution.".to_owned());
            }
            Ok(LuaCommand {
                tool: EXEC_LUA_CODE_ACTION.to_owned(),
                state,
                code,
                target: None,
                class_filter: None,
                custom_check: None,
                limit: None,
                request_id: None,
                return_result,
            })
        }
        "client" => {
            let target = request
                .target
                .ok_or_else(|| "target is required for client execution.".to_owned())?;
            let target = target.trim().to_owned();
            if target.is_empty() {
                return Err("target is required for client execution.".to_owned());
            }
            if target.len() > MAX_TARGET_BYTES {
                return Err(format!(
                    "target exceeds the {} byte limit.",
                    MAX_TARGET_BYTES
                ));
            }
            if return_result
                && matches!(
                    target.to_ascii_lowercase().as_str(),
                    "all" | "tout le monde"
                )
            {
                return Err("return_result requires one client target.".to_owned());
            }
            Ok(LuaCommand {
                tool: EXEC_LUA_CODE_ACTION.to_owned(),
                state,
                code,
                target: Some(target),
                class_filter: None,
                custom_check: None,
                limit: None,
                request_id: None,
                return_result,
            })
        }
        _ => Err("state must be 'server' or 'client'.".to_owned()),
    }
}

fn parse_players_command() -> LuaCommand {
    LuaCommand {
        tool: PLAYERS_ACTION.to_owned(),
        state: "server".to_owned(),
        code: "players".to_owned(),
        target: None,
        class_filter: None,
        custom_check: None,
        limit: None,
        request_id: None,
        return_result: true,
    }
}

fn parse_entities_command(request: BridgeRequest) -> Result<LuaCommand, String> {
    let class_filter = request.class_filter.map(|value| value.trim().to_owned());
    if class_filter.as_ref().is_some_and(|value| value.len() > MAX_TARGET_BYTES) {
        return Err(format!(
            "class_filter exceeds the {} byte limit.",
            MAX_TARGET_BYTES
        ));
    }
    let limit = request.limit.unwrap_or(100);
    if limit == 0 || limit > MAX_ENTITY_LIMIT {
        return Err(format!("limit must be between 1 and {}.", MAX_ENTITY_LIMIT));
    }
    if request
        .custom_check
        .as_ref()
        .is_some_and(|value| value.len() > MAX_LUA_CODE_BYTES)
    {
        return Err(format!(
            "customCheck exceeds the {} byte limit.",
            MAX_LUA_CODE_BYTES
        ));
    }
    Ok(LuaCommand {
        tool: ENTITIES_ACTION.to_owned(),
        state: "server".to_owned(),
        code: "entities".to_owned(),
        target: None,
        class_filter: class_filter.filter(|value| !value.is_empty()),
        custom_check: request
            .custom_check
            .filter(|value| !value.trim().is_empty())
            .map(|value| value.trim().to_owned()),
        limit: Some(limit),
        request_id: None,
        return_result: true,
    })
}

fn parse_screenshot_command(request: BridgeRequest) -> Result<LuaCommand, String> {
    let target = request
        .target
        .ok_or_else(|| "target is required for a screenshot.".to_owned())?;
    let target = target.trim().to_owned();
    if target.is_empty() {
        return Err("target is required for a screenshot.".to_owned());
    }
    if target.len() > MAX_TARGET_BYTES {
        return Err(format!(
            "target exceeds the {} byte limit.",
            MAX_TARGET_BYTES
        ));
    }
    if matches!(
        target.to_ascii_lowercase().as_str(),
        "all" | "tout le monde"
    ) {
        return Err("a screenshot target must identify one client.".to_owned());
    }

    Ok(LuaCommand {
        tool: SCREENSHOT_ACTION.to_owned(),
        state: "client".to_owned(),
        code: "screenshot".to_owned(),
        target: Some(target),
        class_filter: None,
        custom_check: None,
        limit: None,
        request_id: None,
        return_result: false,
    })
}

fn queue_screenshot(
    mut command: LuaCommand,
) -> Result<(String, Receiver<Result<Vec<u8>, String>>), String> {
    let request_id = format!("s{}", NEXT_SCREENSHOT_ID.fetch_add(1, Ordering::Relaxed));
    let (sender, receiver) = mpsc::channel();
    command.request_id = Some(request_id.clone());

    screenshot_state()
        .lock()
        .map_err(|_| "screenshot state lock poisoned".to_owned())?
        .insert(request_id.clone(), sender);

    if let Ok(mut commands) = command_state().lock() {
        commands.push_back(command);
        Ok((request_id, receiver))
    } else {
        remove_screenshot(&request_id);
        Err("command queue lock poisoned".to_owned())
    }
}

fn queue_exec_result(
    mut command: LuaCommand,
) -> Result<(String, Receiver<Result<String, String>>), String> {
    let request_id = format!("e{}", NEXT_EXEC_ID.fetch_add(1, Ordering::Relaxed));
    let (sender, receiver) = mpsc::channel();
    command.request_id = Some(request_id.clone());

    exec_result_state()
        .lock()
        .map_err(|_| "exec result state lock poisoned".to_owned())?
        .insert(request_id.clone(), sender);

    if let Ok(mut commands) = command_state().lock() {
        commands.push_back(command);
        Ok((request_id, receiver))
    } else {
        remove_exec_result(&request_id);
        Err("command queue lock poisoned".to_owned())
    }
}

fn request_body(request: &str) -> String {
    if request == STATUS_REQUEST {
        queue_status_log();
        return status_json();
    }

    let request: BridgeRequest = match serde_json::from_str(request) {
        Ok(request) => request,
        Err(_) => return r#"{"error":"invalid request"}"#.to_owned(),
    };

    match request.action.as_str() {
        "status" => {
            queue_status_log();
            status_json()
        }
        EXEC_LUA_CODE_ACTION => match parse_exec_command(request) {
            Ok(command) => {
                if command.return_result {
                    let result = match queue_exec_result(command) {
                        Ok((request_id, receiver)) => {
                            match receiver.recv_timeout(EXEC_RESULT_TIMEOUT) {
                                Ok(result) => result,
                                Err(mpsc::RecvTimeoutError::Timeout) => {
                                    remove_exec_result(&request_id);
                                    Err("Lua execution timed out.".to_owned())
                                }
                                Err(mpsc::RecvTimeoutError::Disconnected) => {
                                    remove_exec_result(&request_id);
                                    Err("Lua execution was interrupted.".to_owned())
                                }
                            }
                        }
                        Err(error) => Err(error),
                    };
                    return exec_result_response(result);
                }
                let message = match command.state.as_str() {
                    "server" => "Lua code queued for server execution.",
                    _ => "Lua code queued for client execution.",
                };
                queue_command(command);
                command_response(true, message)
            }
            Err(error) => command_response(false, &error),
        },
        PLAYERS_ACTION => query_response(Ok(parse_players_command())),
        ENTITIES_ACTION => query_response(parse_entities_command(request)),
        _ => r#"{"error":"unknown request"}"#.to_owned(),
    }
}

fn query_response(command: Result<LuaCommand, String>) -> String {
    let result = match command.and_then(queue_exec_result) {
        Ok((request_id, receiver)) => match receiver.recv_timeout(EXEC_RESULT_TIMEOUT) {
            Ok(result) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                remove_exec_result(&request_id);
                Err("GMod query timed out.".to_owned())
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                remove_exec_result(&request_id);
                Err("GMod query was interrupted.".to_owned())
            }
        },
        Err(error) => Err(error),
    };
    exec_result_response(result)
}

fn exec_result_response(result: Result<String, String>) -> String {
    match result {
        Ok(payload) => match serde_json::from_str::<serde_json::Value>(&payload) {
            Ok(wrapper) => match wrapper.get("value") {
                Some(value) => serde_json::json!({"ok": true, "result": value}).to_string(),
                None => command_response(false, "Lua result payload is missing its value."),
            },
            Err(_) => command_response(false, "Lua result payload is invalid JSON."),
        },
        Err(error) => command_response(false, &error),
    }
}

fn send_screenshot_response(
    stream: &mut TcpStream,
    result: Result<Vec<u8>, String>,
) -> io::Result<()> {
    match result {
        Ok(data) => {
            serde_json::to_writer(
                &mut *stream,
                &ScreenshotResponse {
                    ok: true,
                    format: "jpeg",
                    size: data.len(),
                },
            )
            .map_err(io::Error::other)?;
            stream.write_all(b"\n")?;
            stream.write_all(&data)
        }
        Err(message) => writeln!(stream, "{}", command_response(false, &message)),
    }
}

fn handle_screenshot_request(stream: &mut TcpStream, request: BridgeRequest) -> io::Result<()> {
    let result = match parse_screenshot_command(request).and_then(queue_screenshot) {
        Ok((request_id, receiver)) => {
            let result = match receiver.recv_timeout(SCREENSHOT_TIMEOUT) {
                Ok(result) => result,
                Err(mpsc::RecvTimeoutError::Timeout) => Err("Screenshot timed out.".to_owned()),
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    Err("Screenshot capture was interrupted.".to_owned())
                }
            };
            remove_screenshot(&request_id);
            result
        }
        Err(error) => Err(error),
    };
    send_screenshot_response(stream, result)
}

fn queue_status_log() {
    queue_command(LuaCommand {
        tool: "gmod_status".to_owned(),
        state: "server".to_owned(),
        code: "status".to_owned(),
        target: None,
        class_filter: None,
        custom_check: None,
        limit: None,
        request_id: None,
        return_result: false,
    });
}

fn start_bridge() -> io::Result<()> {
    let mut bridge_state = bridge_state()
        .lock()
        .map_err(|_| io::Error::other("bridge state lock poisoned"))?;
    if bridge_state.is_some() {
        return Ok(());
    }

    let listener = TcpListener::bind(BIND_ADDRESS)?;
    listener.set_nonblocking(true)?;

    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let thread = thread::Builder::new()
        .name("gmod-mcp-bridge".to_owned())
        .spawn(move || run_server(listener, thread_stop))?;

    *bridge_state = Some(Bridge { stop, thread });
    println!("[gmod-mcp] bridge listening on {BIND_ADDRESS}");
    Ok(())
}

fn stop_bridge() {
    let bridge = bridge_state()
        .lock()
        .ok()
        .and_then(|mut state| state.take());
    if let Some(bridge) = bridge {
        bridge.stop.store(true, Ordering::Relaxed);
        let _ = bridge.thread.join();
    }
}

fn run_server(listener: TcpListener, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                if let Err(error) = handle_connection(stream, &stop) {
                    eprintln!("[gmod-mcp] connection error: {error}");
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => {
                eprintln!("[gmod-mcp] accept error: {error}");
                break;
            }
        }
    }
}

fn handle_connection(mut stream: TcpStream, stop: &AtomicBool) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_millis(50)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;

    let mut request = String::new();
    let mut reader = io::BufReader::new(&mut stream);
    loop {
        match reader.read_line(&mut request) {
            Ok(_) => break,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) =>
            {
                if stop.load(Ordering::Acquire) {
                    return Ok(());
                }
            }
            Err(error) => return Err(error),
        }
    }

    let request = request.trim();
    if let Ok(screenshot_request) = serde_json::from_str::<BridgeRequest>(request) {
        if screenshot_request.action == SCREENSHOT_ACTION {
            return handle_screenshot_request(&mut stream, screenshot_request);
        }
    }

    let body = request_body(request);

    writeln!(stream, "{body}")
}

#[cfg(test)]
mod tests {
    use super::*;

    static TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    fn lock_tests() -> std::sync::MutexGuard<'static, ()> {
        TEST_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .expect("test lock should work")
    }

    #[test]
    fn status_request_works() {
        let _lock = lock_tests();
        clear_commands();
        update_status(true, "Garry's Mod is connected.2".to_owned());

        let listener = TcpListener::bind("127.0.0.1:0").expect("test listener should bind");
        let address = listener
            .local_addr()
            .expect("test address should be available");
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("test connection should arrive");
            handle_connection(stream, &thread_stop).expect("status request should be handled");
        });

        let mut stream = TcpStream::connect(address).expect("test bridge should accept TCP");
        stream
            .write_all(format!("{STATUS_REQUEST}\n").as_bytes())
            .expect("request should be sent");

        let mut response = String::new();
        io::BufReader::new(&mut stream)
            .read_line(&mut response)
            .expect("response should be readable");
        stop.store(true, Ordering::Release);
        thread.join().expect("status thread should stop");

        assert_eq!(
            response.trim(),
            r#"{"connected":true,"message":"Garry's Mod is connected.2"}"#
        );

        let command = command_state()
            .lock()
            .expect("command lock should work")
            .pop_front()
            .expect("status command should be queued");
        assert_eq!(command.tool, "gmod_status");
    }

    #[test]
    fn status_message_is_json_escaped() {
        let _lock = lock_tests();
        update_status(true, "quote: \" and slash: \\".to_owned());

        assert_eq!(
            status_json(),
            r#"{"connected":true,"message":"quote: \" and slash: \\"}"#
        );
    }

    #[test]
    fn server_exec_request_queues_command() {
        let _lock = lock_tests();
        clear_commands();

        let response =
            request_body(r#"{"action":"exec_lua_code","state":"server","code":"print('ok')"}"#);
        assert_eq!(
            response,
            r#"{"ok":true,"message":"Lua code queued for server execution."}"#
        );

        let command = command_state()
            .lock()
            .expect("command lock should work")
            .pop_front()
            .expect("server command should be queued");
        assert_eq!(command.state, "server");
        assert_eq!(command.tool, "exec_lua_code");
        assert_eq!(command.code, "print('ok')");
        assert!(command.target.is_none());
    }

    #[test]
    fn client_exec_requires_target_and_accepts_all() {
        let _lock = lock_tests();
        clear_commands();

        assert_eq!(
            request_body(r#"{"action":"exec_lua_code","state":"client","code":"print('x')"}"#),
            r#"{"ok":false,"message":"target is required for client execution."}"#
        );

        assert_eq!(
            request_body(
                r#"{"action":"exec_lua_code","state":"client","code":"print('x')","target":"all"}"#,
            ),
            r#"{"ok":true,"message":"Lua code queued for client execution."}"#
        );
        let command = command_state()
            .lock()
            .expect("command lock should work")
            .pop_front()
            .expect("client command should be queued");
        assert_eq!(command.tool, "exec_lua_code");
        assert_eq!(command.target.as_deref(), Some("all"));
    }

    #[test]
    fn return_result_request_preserves_target_and_value() {
        let _lock = lock_tests();
        let command = parse_exec_command(BridgeRequest {
            action: EXEC_LUA_CODE_ACTION.to_owned(),
            state: Some("client".to_owned()),
            code: Some("return 42".to_owned()),
            target: Some("mmathis".to_owned()),
            class_filter: None,
            custom_check: None,
            limit: None,
            return_result: Some(true),
        })
        .expect("returning client command should parse");

        assert!(command.return_result);
        assert_eq!(command.target.as_deref(), Some("mmathis"));
        assert_eq!(
            exec_result_response(Ok(r#"{"value":42}"#.to_owned())),
            r#"{"ok":true,"result":42}"#
        );
    }

    #[test]
    fn entity_query_keeps_filter_and_limit() {
        let command = parse_entities_command(BridgeRequest {
            action: ENTITIES_ACTION.to_owned(),
            state: None,
            code: None,
            target: None,
            class_filter: Some("prop_".to_owned()),
            custom_check: Some("return entity:GetClass() == 'prop_physics'".to_owned()),
            limit: Some(25),
            return_result: None,
        })
        .expect("entity query should parse");

        assert_eq!(command.tool, ENTITIES_ACTION);
        assert_eq!(command.class_filter.as_deref(), Some("prop_"));
        assert_eq!(
            command.custom_check.as_deref(),
            Some("return entity:GetClass() == 'prop_physics'")
        );
        assert_eq!(command.limit, Some(25));
        assert!(parse_entities_command(BridgeRequest {
            action: ENTITIES_ACTION.to_owned(),
            state: None,
            code: None,
            target: None,
            class_filter: None,
            custom_check: None,
            limit: Some(MAX_ENTITY_LIMIT + 1),
            return_result: None,
        })
        .is_err());
    }

    #[test]
    fn screenshot_request_queues_one_client_and_keeps_binary_data() {
        let _lock = lock_tests();
        clear_commands();
        fail_pending_screenshots("test reset");

        assert!(parse_screenshot_command(BridgeRequest {
            action: SCREENSHOT_ACTION.to_owned(),
            state: None,
            code: None,
            target: Some("all".to_owned()),
            class_filter: None,
            custom_check: None,
            limit: None,
            return_result: None,
        })
        .is_err());

        let command = parse_screenshot_command(BridgeRequest {
            action: SCREENSHOT_ACTION.to_owned(),
            state: None,
            code: None,
            target: Some("76561198000000000".to_owned()),
            class_filter: None,
            custom_check: None,
            limit: None,
            return_result: None,
        })
        .expect("screenshot target should be valid");
        let (request_id, receiver) = queue_screenshot(command).expect("screenshot should queue");

        let command = command_state()
            .lock()
            .expect("command lock should work")
            .pop_front()
            .expect("screenshot command should be queued");
        assert_eq!(command.tool, SCREENSHOT_ACTION);
        assert_eq!(command.target.as_deref(), Some("76561198000000000"));
        assert_eq!(command.request_id.as_deref(), Some(request_id.as_str()));

        complete_screenshot(request_id, Ok(vec![0, 255, 1]));
        assert_eq!(
            receiver
                .recv_timeout(Duration::from_millis(10))
                .expect("screenshot should return")
                .expect("screenshot should succeed"),
            vec![0, 255, 1]
        );
    }

    #[test]
    fn idle_connection_stops_promptly() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("test listener should bind");
        let address = listener
            .local_addr()
            .expect("test address should be available");
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("test connection should arrive");
            handle_connection(stream, &thread_stop).expect("stopping should be clean");
        });

        let _stream = TcpStream::connect(address).expect("test connection should succeed");
        stop.store(true, Ordering::Release);
        thread.join().expect("connection thread should stop");
    }
}
