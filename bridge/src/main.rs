// agent-browser -> omarchy-shell bridge.
//
// Watches $XDG_RUNTIME_DIR/agent-browser for `<session>.stream` files (each one
// holds the localhost port of that session's WebSocket screencast server),
// connects to every session it finds, and prints one JSON line per state change
// on stdout for the shell-side service to parse.
//
// Every connected session is tracked and reported, but only one at a time is
// "shown" — its frames are the ones written to disk. The shell picks by writing
// {"select":"<name>"} on stdin, or {"select":""} to go back to following
// whichever session is painting.
//
// Frames are written to disk rather than piped through stdout so a 200KB frame
// never has to survive a line-oriented parser. Two slots alternate: QML only
// reloads an Image when the URL actually changes, and writing through a temp
// file + rename means the panel can never catch a half-written frame.

mod describe;

use std::collections::BTreeMap;
use std::io::Write as _;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use base64::Engine as _;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Map, Value};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

const RESCAN_MS: u64 = 2000;
// How long a session counts as "painting" after its last visual change. Drives
// the per-session activity dots, not the panel's own hide timing.
const PAINTING_MS: u64 = 1500;
// Sessions nobody is looking at still stream — their frames feed the activity
// dots and the cached "latest" that makes switching instant — but at this rate
// rather than the full one. Every idle stream costs its browser a JPEG encode
// per frame, so with several sessions this is most of the steady-state cost.
const IDLE_FPS: u32 = 1;
// How long a session keeps full rate after it was last shown. In automatic
// mode two busy sessions can trade the shown slot several times a second, and
// retuning means a socket reconnect — hysteresis makes that trade free.
const DEMOTE_MS: u64 = 10000;
const PUBLISH_MS: u64 = 700;

enum Event {
    Stdin(String),
    Scan,
    Publish,
    Ws {
        name: String,
        generation: u64,
        msg: Value,
    },
    WsClosed {
        name: String,
        generation: u64,
    },
    RetryElapsed {
        name: String,
        generation: u64,
    },
    Located {
        name: String,
        point: Option<(f64, f64)>,
    },
    StdoutGone,
    Shutdown,
}

struct Session {
    name: String,
    port: u16,
    generation: u64,
    task: Option<tokio::task::AbortHandle>,
    connected: bool,
    tab_count: usize,
    url: String,
    title: String,
    frame: String,
    latest: String, // base64 payload of the last changed frame
    seq: u64,
    vw: u64,
    vh: u64,
    last_change_at: u64, // 0 = never painted
    refs: Value,
    locating: bool,
    retry_pending: bool,
    fps: u32,
    shown_at: u64,
}

struct State {
    tx: mpsc::UnboundedSender<Event>,
    out: std::sync::mpsc::Sender<String>,
    start: Instant,
    watch_dir: PathBuf,
    out_dir: PathBuf,
    max_fps: u32,
    only_sessions: Vec<String>,
    track_pointer: bool,
    cli: String,
    // BTreeMap so iteration — and with it the tie-break when two sessions are
    // equally fresh — is deterministic, in the same name order the session
    // list is reported in.
    sessions: BTreeMap<String, Session>,
    next_generation: u64,
    selected: String, // "" means follow whichever session is painting
    shown_name: String,
    slot: u8,
    last_line: String,
    warned_frame_write: bool,
}

impl State {
    fn now_ms(&self) -> u64 {
        // +1 keeps 0 free as the "never" sentinel in last_change_at.
        self.start.elapsed().as_millis() as u64 + 1
    }

    // Lines go through a dedicated writer thread rather than being written
    // here: a shell that stops draining the pipe must stall the panel, not
    // this loop — a parked loop stops acking frames and, worse, stops hearing
    // SIGTERM. Buffering in memory until then is what the Node bridge did too.
    fn write_line(&mut self, line: String) {
        let _ = self.out.send(line);
    }

    fn emit(&mut self, obj: Value) {
        let line = obj.to_string();
        if line == self.last_line {
            return;
        }
        self.last_line = line.clone();
        self.write_line(line);
    }

    // Actions are events, not state: two identical ones in a row are two things
    // that happened, so they bypass the deduplication above and do not disturb it.
    fn emit_action(&mut self, obj: Value) {
        self.write_line(obj.to_string());
    }

    fn usable(s: &Session) -> bool {
        s.connected && s.tab_count > 0
    }

    // The session worth showing is the one that most recently painted. Falling
    // back to any connected session keeps a freshly opened, still-blank browser
    // visible instead of blinking the panel in only once the first frame lands.
    fn auto_session(&self) -> Option<&Session> {
        let mut best: Option<&Session> = None;
        for s in self.sessions.values() {
            if !Self::usable(s) {
                continue;
            }
            if best.is_none_or(|b| s.last_change_at > b.last_change_at) {
                best = Some(s);
            }
        }
        best
    }

    fn shown_session_name(&self) -> Option<String> {
        if !self.selected.is_empty() {
            if let Some(pinned) = self.sessions.get(&self.selected) {
                if Self::usable(pinned) {
                    return Some(pinned.name.clone());
                }
            }
        }
        self.auto_session().map(|s| s.name.clone())
    }

    // A frame that cannot be written is otherwise invisible — the bridge keeps
    // running and publishing, just with a stale or empty picture — so the first
    // failure is worth one line in the journal. One, not one per frame: a
    // full disk at 30fps should not flood the log.
    fn warn_frame_write(&mut self, err: &std::io::Error) {
        if self.warned_frame_write {
            return;
        }
        self.warned_frame_write = true;
        eprintln!(
            "omarchy-browser-minimap bridge: writing frames to {} failed: {err}",
            self.out_dir.display()
        );
    }

    // Keep the shown session at full rate and everything long out of the
    // spotlight at IDLE_FPS. The rate rides on the socket URL, so changing it
    // means a reconnect — the swap costs nothing but frames that were already
    // stale.
    fn retune(&mut self, shown: Option<&str>) {
        if self.max_fps <= IDLE_FPS {
            return;
        }
        let now = self.now_ms();
        let mut reopen = Vec::new();
        for s in self.sessions.values_mut() {
            if Some(s.name.as_str()) == shown {
                s.shown_at = now;
            }
            if s.retry_pending {
                continue;
            }
            let want = if now - s.shown_at < DEMOTE_MS {
                self.max_fps
            } else {
                IDLE_FPS
            };
            if want != s.fps {
                s.fps = want;
                reopen.push(s.name.clone());
            }
        }
        for name in reopen {
            self.open_stream(&name);
        }
    }

    fn publish(&mut self) {
        let shown = self.shown_session_name();
        self.retune(shown.as_deref());
        let now = self.now_ms();

        // Report every session, so the panel can offer a switcher and the bar
        // icon can show that something is happening even on a session you are
        // not looking at.
        let mut all = Vec::new();
        for item in self.sessions.values() {
            if !Self::usable(item) {
                continue;
            }
            all.push(json!({
                "name": item.name,
                "url": item.url,
                "title": item.title,
                "painting": item.last_change_at > 0 && now - item.last_change_at < PAINTING_MS,
            }));
        }

        let Some(shown) = shown else {
            self.shown_name.clear();
            let auto = self.selected.is_empty();
            self.emit(json!({ "type": "state", "live": false, "auto": auto, "sessions": all }));
            return;
        };

        // Covers automatic switches as well as deliberate ones: whichever way
        // the shown session changed, its picture is rewritten before it is
        // announced.
        if shown != self.shown_name {
            self.refresh_shown(&shown);
        }
        self.shown_name = shown.clone();

        let Some(s) = self.sessions.get(&shown) else {
            return;
        };
        let state = json!({
            "type": "state",
            "live": true,
            "shown": s.name,
            "auto": self.selected.is_empty(),
            "pinnedMissing": !self.selected.is_empty() && !self.sessions.contains_key(&self.selected),
            "url": s.url,
            "title": s.title,
            "frame": s.frame,
            "seq": s.seq,
            "vw": s.vw,
            "vh": s.vh,
            "sessions": all,
        });
        self.emit(state);
    }

    // The two frame slots are shared by every session, so a session's stored
    // path can be holding some other session's picture by the time you come
    // back to it. Whenever the shown session changes, its own last frame is
    // written afresh — that also means switching shows the page immediately
    // instead of waiting for it to repaint. A session that has never painted
    // reports no frame at all, which is the one case where the panel should go
    // blank rather than keep showing what was there before.
    fn refresh_shown(&mut self, name: &str) {
        let Some(s) = self.sessions.get(name) else {
            return;
        };
        if s.latest.is_empty() {
            if let Some(s) = self.sessions.get_mut(name) {
                s.frame.clear();
            }
            return;
        }
        match write_frame(&self.out_dir, &mut self.slot, &s.latest) {
            Ok(path) => {
                if let Some(s) = self.sessions.get_mut(name) {
                    s.frame = path.to_string_lossy().into_owned();
                    s.seq += 1;
                }
            }
            Err(err) => self.warn_frame_write(&err),
        }
    }

    fn select(&mut self, name: &str) {
        if name == self.selected {
            return;
        }
        self.selected = name.to_string();
        // publish() refreshes the frame whenever the shown session changes, so
        // a manual switch needs nothing extra here.
        self.publish();
    }

    fn connect(&mut self, name: &str, port: u16) {
        if let Some(existing) = self.sessions.get(name) {
            if existing.port == port {
                return;
            }
            self.drop_session(name);
        }

        // Full rate from the start: a fresh session is the one most likely to
        // be shown next, and retune() demotes it soon enough if it never is.
        let s = Session {
            name: name.to_string(),
            port,
            generation: 0,
            task: None,
            connected: false,
            tab_count: 0,
            url: String::new(),
            title: String::new(),
            frame: String::new(),
            latest: String::new(),
            seq: 0,
            vw: 0,
            vh: 0,
            last_change_at: 0,
            refs: Value::Null,
            locating: false,
            retry_pending: false,
            fps: self.max_fps,
            shown_at: self.now_ms(),
        };
        self.sessions.insert(name.to_string(), s);
        self.open_stream(name);
    }

    // One screencast socket for one session, at one frame rate. pacing=ack
    // means the server holds the next frame until this client says it rendered
    // the last one, so a stalled panel drops frames instead of building a
    // backlog of stale ones. Both settings must ride on the URL to cover the
    // opening frame.
    fn open_stream(&mut self, name: &str) {
        self.next_generation += 1;
        let generation = self.next_generation;
        let Some(s) = self.sessions.get_mut(name) else {
            return;
        };
        s.generation = generation;
        if let Some(old) = s.task.take() {
            old.abort();
        }

        let url = format!("ws://127.0.0.1:{}/?pacing=ack&maxFps={}", s.port, s.fps);
        let tx = self.tx.clone();
        let task_name = name.to_string();
        let handle = tokio::spawn(async move {
            let name = task_name;
            if let Ok((mut ws, _)) = tokio_tungstenite::connect_async(&url).await {
                while let Some(item) = ws.next().await {
                    let text = match item {
                        Ok(Message::Text(t)) => t,
                        Ok(Message::Close(_)) | Err(_) => break,
                        Ok(_) => continue,
                    };
                    let Ok(msg) = serde_json::from_str::<Value>(text.as_str()) else {
                        continue;
                    };
                    // Acknowledge first so the next frame is already in flight
                    // while this one is deduplicated and written.
                    if msg["type"] == "frame" {
                        let mut ack = Map::new();
                        ack.insert("type".into(), "ack".into());
                        if let Some(seq) = msg.get("seq") {
                            ack.insert("seq".into(), seq.clone());
                        }
                        if ws
                            .send(Message::text(Value::Object(ack).to_string()))
                            .await
                            .is_err()
                        {
                            break;
                        }
                    }
                    if tx
                        .send(Event::Ws {
                            name: name.clone(),
                            generation,
                            msg,
                        })
                        .is_err()
                    {
                        return;
                    }
                }
            }
            let _ = tx.send(Event::WsClosed { name, generation });
        });
        if let Some(s) = self.sessions.get_mut(name) {
            s.task = Some(handle.abort_handle());
        }
    }

    fn drop_session(&mut self, name: &str) {
        if let Some(s) = self.sessions.remove(name) {
            if let Some(task) = s.task {
                task.abort();
            }
        }
    }

    fn scan(&mut self) {
        let entries: Vec<String> = std::fs::read_dir(&self.watch_dir)
            .map(|rd| {
                rd.filter_map(|e| e.ok())
                    .filter_map(|e| e.file_name().into_string().ok())
                    .collect()
            })
            .unwrap_or_default();

        let mut live = Vec::new();
        for entry in entries {
            let Some(name) = entry.strip_suffix(".stream") else {
                continue;
            };
            // A hard allowlist: the bridge never even connects to anything
            // else. Distinct from the soft `select`, which chooses among the
            // sessions it is watching.
            if !self.only_sessions.is_empty() && !self.only_sessions.iter().any(|s| s == name) {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(self.watch_dir.join(&entry)) else {
                continue;
            };
            let Ok(port) = text.trim().parse::<u16>() else {
                continue;
            };
            if port == 0 {
                continue;
            }
            live.push(name.to_string());
            self.connect(name, port);
        }
        let gone: Vec<String> = self
            .sessions
            .keys()
            .filter(|name| !live.contains(name))
            .cloned()
            .collect();
        for name in gone {
            self.drop_session(&name);
        }
        self.publish();
    }

    // Only refs and plain CSS can be resolved this way. Playwright's text= and
    // role= engines are not accepted by `get box`, and the getby* locator
    // commands carry no selector at all, so those actions are named in the
    // feed but never drawn.
    fn resolvable(selector: &str) -> bool {
        if selector.is_empty() {
            return false;
        }
        if selector.starts_with('@') {
            return true;
        }
        !selector.contains('=')
    }

    // One query in flight per session: an agent working quickly should not
    // spawn a process per action faster than they can complete. Resolving
    // where a click landed costs one read-only query per action; with
    // --track off, the bridge never issues a command of any kind into a
    // session.
    fn locate(&mut self, name: &str, selector: &str) {
        if !self.track_pointer || !Self::resolvable(selector) {
            return;
        }
        let Some(s) = self.sessions.get_mut(name) else {
            return;
        };
        if s.locating {
            return;
        }
        s.locating = true;

        let cli = self.cli.clone();
        let tx = self.tx.clone();
        let name = name.to_string();
        let selector = selector.to_string();
        tokio::spawn(async move {
            let output = tokio::time::timeout(
                Duration::from_millis(2000),
                tokio::process::Command::new(&cli)
                    .args(["get", "box", &selector, "--json"])
                    .env("AGENT_BROWSER_SESSION", &name)
                    .stdin(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .kill_on_drop(true)
                    .output(),
            )
            .await;

            let point = (|| {
                let out = output.ok()?.ok()?;
                let parsed: Value = serde_json::from_slice(&out.stdout).ok()?;
                if parsed["success"] != true {
                    return None;
                }
                let b = &parsed["data"];
                let x = b["x"].as_f64()?;
                let y = b["y"].as_f64()?;
                // The centre of the element is where a click is aimed.
                Some((
                    x + b["width"].as_f64().unwrap_or(0.0) / 2.0,
                    y + b["height"].as_f64().unwrap_or(0.0) / 2.0,
                ))
            })();
            let _ = tx.send(Event::Located { name, point });
        });
    }

    fn on_ws(&mut self, name: &str, generation: u64, mut msg: Value) {
        let now = self.now_ms();
        // A socket replaced by a retune can still have messages in flight; the
        // session has moved on, so they belong to nobody.
        let Some(s) = self.sessions.get_mut(name) else {
            return;
        };
        if s.generation != generation {
            return;
        }

        // Copied out so the arms can move payloads out of `msg` with take():
        // the refs table, the tab list and above all the frame bytes are used
        // once each, and a frame is a ~200KB string that has no business being
        // copied on the hot path.
        let msg_type = msg["type"].as_str().unwrap_or("").to_owned();
        match msg_type.as_str() {
            "status" => {
                s.connected = msg["connected"] == true;
                if let Some(w) = msg["viewportWidth"].as_u64().filter(|w| *w > 0) {
                    s.vw = w;
                }
                if let Some(h) = msg["viewportHeight"].as_u64().filter(|h| *h > 0) {
                    s.vh = h;
                }
                self.publish();
            }

            // An agent works by taking a snapshot and then clicking the refs it
            // returned. The snapshot's result carries the whole ref table —
            // name and role for each — and it is broadcast to us too, so
            // "click @e5" can be reported as the thing it actually clicked
            // rather than as "@e5".
            "result" => {
                if msg["action"] == "snapshot" && msg["data"]["refs"].is_object() {
                    s.refs = msg["data"]["refs"].take();
                }
            }

            "tabs" => {
                let tabs = match msg["tabs"].take() {
                    Value::Array(tabs) => tabs,
                    _ => Vec::new(),
                };
                s.tab_count = tabs.len();
                let active = tabs.iter().find(|t| t["active"] == true).or(tabs.first());
                s.url = active
                    .and_then(|t| t["url"].as_str())
                    .unwrap_or("")
                    .to_string();
                s.title = active
                    .and_then(|t| t["title"].as_str())
                    .unwrap_or("")
                    .to_string();
                self.publish();
            }

            // agent-browser broadcasts every command it runs to passive stream
            // clients, so the feed costs nothing but parsing: no polling, no
            // commands issued back into a session an agent is in the middle of
            // driving.
            "command" => {
                let action = msg["action"].as_str().unwrap_or("").to_owned();
                // Our own box queries come back round the stream; they are
                // plumbing, not something the agent did.
                if action.is_empty() || action == "boundingbox" {
                    return;
                }
                let p = if msg["params"].is_object() {
                    msg["params"].take()
                } else {
                    json!({})
                };
                let label = describe::describe(&action, &p, &s.refs);
                let point = match (p["x"].as_f64(), p["y"].as_f64()) {
                    (Some(x), Some(y)) => Some((x, y)),
                    _ => None,
                };

                let mut event = json!({
                    "type": "action",
                    "session": name,
                    "action": action,
                    "label": label,
                });
                // Only raw pointer commands carry coordinates; selector-driven
                // ones, which is most of what an agent does, have no spatial
                // information.
                if let Some((x, y)) = point {
                    event["x"] = json!(x);
                    event["y"] = json!(y);
                }
                self.emit_action(event);

                if let Some((x, y)) = point {
                    self.emit_action(json!({ "type": "point", "session": name, "x": x, "y": y }));
                } else if describe::pointed(&action) {
                    let selector = p["selector"].as_str().unwrap_or("").to_string();
                    self.locate(name, &selector);
                }
            }

            "frame" => {
                let data = match msg["data"].take() {
                    Value::String(data) if !data.is_empty() => data,
                    _ => return,
                };
                // CDP keeps screencasting a still page at the full frame rate,
                // so "a frame arrived" says nothing about whether the agent is
                // doing anything. Identical pixels re-encode to identical JPEG
                // bytes, which makes comparing the payload a cheap and honest
                // activity signal.
                if data == s.latest {
                    return;
                }
                s.last_change_at = now;
                if let Some(w) = msg["metadata"]["deviceWidth"].as_u64().filter(|w| *w > 0) {
                    s.vw = w;
                }
                if let Some(h) = msg["metadata"]["deviceHeight"].as_u64().filter(|h| *h > 0) {
                    s.vh = h;
                }
                let seq = msg["seq"].as_u64();

                // Only the shown session's pixels reach the disk. The rest are
                // tracked for their activity dot and kept in memory in case you
                // switch to them.
                if self.shown_session_name().as_deref() == Some(name) {
                    match write_frame(&self.out_dir, &mut self.slot, &data) {
                        Ok(path) => {
                            if let Some(s) = self.sessions.get_mut(name) {
                                s.frame = path.to_string_lossy().into_owned();
                                s.seq = match seq {
                                    Some(v) if v > 0 => v,
                                    _ => s.seq + 1,
                                };
                            }
                        }
                        // Keep the previous frame; the failure gets its one
                        // line in the journal.
                        Err(err) => self.warn_frame_write(&err),
                    }
                }
                if let Some(s) = self.sessions.get_mut(name) {
                    s.latest = data;
                }
                self.publish();
            }

            _ => {}
        }
    }

    fn on_ws_closed(&mut self, name: &str, generation: u64) {
        // A retune already replaced this socket deliberately; only the loss of
        // the session's current socket means the session itself is in trouble.
        let Some(s) = self.sessions.get_mut(name) else {
            return;
        };
        if s.generation != generation {
            return;
        }
        s.connected = false;
        self.publish();
        // The daemon can outlive a single browser; retry as long as the stream
        // file is still on disk, and let the rescan handle it if it is not.
        if self.watch_dir.join(format!("{name}.stream")).exists() {
            if let Some(s) = self.sessions.get_mut(name) {
                s.retry_pending = true;
                let tx = self.tx.clone();
                let name = name.to_string();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(1000)).await;
                    let _ = tx.send(Event::RetryElapsed { name, generation });
                });
            }
        }
    }

    // Nothing of this should outlive the process. The frames are the only
    // thing the plugin writes anywhere, and leaving them behind would mean an
    // uninstall left a directory of screenshots sitting in the runtime tree
    // until reboot.
    fn clean_up(&mut self) {
        let names: Vec<String> = self.sessions.keys().cloned().collect();
        for name in names {
            self.drop_session(&name);
        }
        let _ = std::fs::remove_dir_all(&self.out_dir);
    }
}

// The same error shape the old bridge printed. Both channels on purpose:
// stdout is the protocol, stderr is what Service.qml relays to the journal —
// a startup failure that only the (possibly absent) protocol reader saw
// would be invisible exactly when someone is trying to find out why the
// panel never appears.
fn die(message: String) -> ! {
    println!("{}", json!({ "type": "error", "message": message }));
    eprintln!("omarchy-browser-minimap bridge: {message}");
    std::process::exit(1);
}

// Synchronous on purpose: a frame's path — and, on a switch, the switch
// itself — is only announced once the bytes are on disk, and OUT_DIR sits on
// tmpfs by default, where the write is a memory copy. Pointing --out at a
// real disk makes every frame block the loop for the length of the write.
// A free function over the two fields it needs, so a caller can hold a
// session borrowed while writing that session's frame.
fn write_frame(
    out_dir: &std::path::Path,
    slot: &mut u8,
    base64_data: &str,
) -> std::io::Result<PathBuf> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(base64_data)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    *slot ^= 1;
    let target = out_dir.join(format!("frame-{}.jpg", if *slot == 1 { "b" } else { "a" }));
    let tmp = target.with_extension("jpg.tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, &target)?;
    Ok(target)
}

fn flag(args: &[String], name: &str) -> Option<String> {
    let i = args.iter().position(|a| a == name)?;
    args.get(i + 1).cloned()
}

// agent-browser is not necessarily on the PATH the shell inherited.
fn find_cli() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        format!("{home}/.local/share/mise/shims/agent-browser"),
        "/usr/local/bin/agent-browser".to_string(),
        "/usr/bin/agent-browser".to_string(),
    ];
    for c in &candidates {
        if let Ok(meta) = std::fs::metadata(c) {
            if meta.is_file() && meta.permissions().mode() & 0o111 != 0 {
                return c.clone();
            }
        }
    }
    "agent-browser".to_string()
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let runtime_dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| {
        let uid = std::fs::metadata("/proc/self")
            .map(|m| m.uid())
            .unwrap_or(0);
        format!("/run/user/{uid}")
    });
    let watch_dir = PathBuf::from(&runtime_dir).join("agent-browser");
    let out_dir = flag(&args, "--out")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(&runtime_dir).join("omarchy-browser-minimap"));
    let max_fps = flag(&args, "--fps")
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(4)
        .clamp(1, 30);
    let only_sessions: Vec<String> = flag(&args, "--session")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let track_pointer = args.iter().any(|a| a == "--track");

    // An out dir that cannot take frames means a live panel showing nothing
    // forever; better to refuse to start, loudly, than to run blind. The probe
    // catches the directory already existing but belonging to someone else.
    if let Err(err) = std::fs::create_dir_all(&out_dir) {
        die(format!("cannot create {}: {err}", out_dir.display()));
    }
    if let Ok(rd) = std::fs::read_dir(&out_dir) {
        for entry in rd.flatten() {
            let _ = std::fs::remove_file(entry.path());
        }
    }
    let probe = out_dir.join(".probe");
    if let Err(err) = std::fs::write(&probe, b"") {
        die(format!("{} is not writable: {err}", out_dir.display()));
    }
    let _ = std::fs::remove_file(&probe);

    // panic=abort skips every destructor, but the hook still runs — without
    // this, a panic would leave screenshots of whatever page an agent was on
    // sitting in the runtime tree until reboot.
    {
        let dir = out_dir.clone();
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let _ = std::fs::remove_dir_all(&dir);
            default_hook(info);
        }));
    }

    let (tx, mut rx) = mpsc::unbounded_channel::<Event>();

    // All stdout goes through this thread so a reader that stops draining the
    // pipe can never park the event loop (see write_line). A write error means
    // the reader is gone entirely — reported back as an event, because the
    // frames on disk still need cleaning up and that state lives on the loop.
    let (out_tx, out_rx) = std::sync::mpsc::channel::<String>();
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let stdout = std::io::stdout();
            let mut out = stdout.lock();
            for line in out_rx {
                let ok = out
                    .write_all(line.as_bytes())
                    .and_then(|_| out.write_all(b"\n"))
                    .and_then(|_| out.flush())
                    .is_ok();
                if !ok {
                    let _ = tx.send(Event::StdoutGone);
                    return;
                }
            }
        });
    }
    let mut state = State {
        tx: tx.clone(),
        out: out_tx,
        start: Instant::now(),
        watch_dir: watch_dir.clone(),
        out_dir,
        max_fps,
        only_sessions,
        track_pointer,
        cli: find_cli(),
        sessions: BTreeMap::new(),
        next_generation: 0,
        selected: String::new(),
        shown_name: String::new(),
        slot: 0,
        last_line: String::new(),
        warned_frame_write: false,
    };

    // inotify on tmpfs is reliable, but a rescan costs one readdir and removes
    // a whole class of "the panel never woke up" bug reports.
    let _ = std::fs::create_dir_all(&watch_dir);
    if let Ok(ino) = inotify::Inotify::init() {
        let ok = ino
            .watches()
            .add(
                &watch_dir,
                inotify::WatchMask::CREATE
                    | inotify::WatchMask::DELETE
                    | inotify::WatchMask::MODIFY
                    | inotify::WatchMask::MOVED_TO
                    | inotify::WatchMask::MOVED_FROM,
            )
            .is_ok();
        if ok {
            if let Ok(mut stream) = ino.into_event_stream(vec![0u8; 4096]) {
                let tx = tx.clone();
                tokio::spawn(async move {
                    while let Some(Ok(_)) = stream.next().await {
                        if tx.send(Event::Scan).is_err() {
                            return;
                        }
                    }
                });
            }
        }
    } // the rescan below is the fallback

    {
        let tx = tx.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(RESCAN_MS));
            tick.tick().await;
            loop {
                tick.tick().await;
                if tx.send(Event::Scan).is_err() {
                    return;
                }
            }
        });
    }
    {
        // Also republishes on a timer so the per-session painting dots decay
        // without needing a frame to arrive.
        let tx = tx.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(PUBLISH_MS));
            tick.tick().await;
            loop {
                tick.tick().await;
                if tx.send(Event::Publish).is_err() {
                    return;
                }
            }
        });
    }

    // Commands from the shell. One JSON object per line.
    {
        let tx = tx.clone();
        tokio::spawn(async move {
            use tokio::io::AsyncBufReadExt;
            let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if tx.send(Event::Stdin(line)).is_err() {
                    return;
                }
            }
        });
    }

    for kind in [
        tokio::signal::unix::SignalKind::terminate(),
        tokio::signal::unix::SignalKind::interrupt(),
        tokio::signal::unix::SignalKind::hangup(),
    ] {
        if let Ok(mut sig) = tokio::signal::unix::signal(kind) {
            let tx = tx.clone();
            tokio::spawn(async move {
                sig.recv().await;
                let _ = tx.send(Event::Shutdown);
            });
        }
    }

    state.scan();

    while let Some(event) = rx.recv().await {
        match event {
            Event::Stdin(line) => {
                let Ok(msg) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if let Some(name) = msg["select"].as_str() {
                    state.select(name);
                }
            }
            Event::Scan => state.scan(),
            Event::Publish => state.publish(),
            Event::Ws {
                name,
                generation,
                msg,
            } => state.on_ws(&name, generation, msg),
            Event::WsClosed { name, generation } => state.on_ws_closed(&name, generation),
            Event::RetryElapsed { name, generation } => {
                let stale = state
                    .sessions
                    .get(&name)
                    .is_none_or(|s| !s.retry_pending || s.generation != generation);
                if !stale {
                    state.drop_session(&name);
                    state.scan();
                }
            }
            Event::Located { name, point } => {
                if let Some(s) = state.sessions.get_mut(&name) {
                    s.locating = false;
                }
                if let Some((x, y)) = point {
                    state.emit_action(json!({ "type": "point", "session": name, "x": x, "y": y }));
                }
            }
            // A reader that vanished is a reason to stop, not to crash.
            Event::StdoutGone | Event::Shutdown => {
                state.clean_up();
                std::process::exit(0);
            }
        }
    }
}
