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

import crypto from "node:crypto"
import fs from "node:fs"
import path from "node:path"
import readline from "node:readline"

const args = process.argv.slice(2)
function flag(name, fallback) {
  const i = args.indexOf(name)
  return i === -1 || i === args.length - 1 ? fallback : args[i + 1]
}
const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n))
const int = (v, d) => (Number.isFinite(parseInt(v, 10)) ? parseInt(v, 10) : d)

const RUNTIME = process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`
const WATCH_DIR = path.join(RUNTIME, "agent-browser")
const OUT_DIR = flag("--out", path.join(RUNTIME, "omarchy-browser-minimap"))
const MAX_FPS = clamp(int(flag("--fps"), 4), 1, 30)
// A hard pin: the bridge never even connects to anything else. Distinct from
// the soft `select` below, which chooses among the sessions it is watching.
const ONLY_SESSION = flag("--session", "")
// fs.watch on tmpfs is reliable, but a rescan costs one readdir and removes a
// whole class of "the panel never woke up" bug reports.
const RESCAN_MS = 2000
// How long a session counts as "painting" after its last visual change. Drives
// the per-session activity dots, not the panel's own hide timing.
const PAINTING_MS = 1500

fs.mkdirSync(OUT_DIR, { recursive: true })
for (const f of fs.readdirSync(OUT_DIR)) {
  try { fs.unlinkSync(path.join(OUT_DIR, f)) } catch {}
}

/** @type {Map<string, any>} */
const sessions = new Map()
let selected = ""      // "" means follow whichever session is painting
let shownName = ""
let slot = 0
let lastLine = ""

function emit(obj) {
  const line = JSON.stringify(obj)
  if (line === lastLine) return
  lastLine = line
  process.stdout.write(line + "\n")
}

function usable(s) {
  return s.connected && s.tabCount > 0
}

// The session worth showing is the one that most recently painted. Falling back
// to any connected session keeps a freshly opened, still-blank browser visible
// instead of blinking the panel in only once the first frame lands.
function autoSession() {
  let best = null
  for (const s of sessions.values()) {
    if (!usable(s)) continue
    if (!best || (s.lastChangeAt || 0) > (best.lastChangeAt || 0)) best = s
  }
  return best
}

function shownSession() {
  if (selected !== "") {
    const pinned = sessions.get(selected)
    if (pinned && usable(pinned)) return pinned
  }
  return autoSession()
}

function writeFrame(base64) {
  slot = slot ^ 1
  const target = path.join(OUT_DIR, `frame-${slot ? "b" : "a"}.jpg`)
  const tmp = `${target}.tmp`
  fs.writeFileSync(tmp, Buffer.from(base64, "base64"))
  fs.renameSync(tmp, target)
  return target
}

function publish() {
  const s = shownSession()
  const now = Date.now()

  // Report every session, so the panel can offer a switcher and the bar icon
  // can show that something is happening even on a session you are not
  // looking at.
  const all = []
  for (const item of sessions.values()) {
    if (!usable(item)) continue
    all.push({
      name: item.name,
      url: item.url || "",
      title: item.title || "",
      painting: item.lastChangeAt > 0 && now - item.lastChangeAt < PAINTING_MS,
    })
  }
  all.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))

  if (!s) {
    shownName = ""
    emit({ type: "state", live: false, auto: selected === "", sessions: all })
    return
  }

  shownName = s.name
  emit({
    type: "state",
    live: true,
    shown: s.name,
    auto: selected === "",
    pinnedMissing: selected !== "" && !sessions.has(selected),
    url: s.url || "",
    title: s.title || "",
    frame: s.frame || "",
    seq: s.seq || 0,
    vw: s.vw || 0,
    vh: s.vh || 0,
    sessions: all,
  })
}

// Switching sessions should show that page immediately rather than waiting for
// it to repaint, so every session keeps its most recent frame in memory.
function showLatestFrom(s) {
  if (!s || !s.latest) return
  try {
    s.frame = writeFrame(s.latest)
    s.seq = (s.seq || 0) + 1
  } catch {}
}

function select(name) {
  const next = typeof name === "string" ? name : ""
  if (next === selected) return
  selected = next
  const s = shownSession()
  if (s && s.name !== shownName) showLatestFrom(s)
  publish()
}

function connect(name, port) {
  const existing = sessions.get(name)
  if (existing && existing.port === port) return
  if (existing) drop(name)

  const s = {
    name, port, connected: false, tabCount: 0,
    url: "", title: "", frame: "", latest: "", seq: 0, vw: 0, vh: 0,
    lastChangeAt: 0, frameHash: "", ws: null, retry: null,
  }
  sessions.set(name, s)

  // pacing=ack means the server holds the next frame until this client says it
  // rendered the last one, so a stalled panel drops frames instead of building
  // a backlog of stale ones. Both settings must ride on the URL to cover the
  // opening frame.
  const ws = new WebSocket(`ws://127.0.0.1:${port}/?pacing=ack&maxFps=${MAX_FPS}`)
  s.ws = ws

  ws.onmessage = (ev) => {
    let msg
    try { msg = JSON.parse(ev.data) } catch { return }

    if (msg.type === "status") {
      s.connected = msg.connected === true
      if (msg.viewportWidth) s.vw = msg.viewportWidth
      if (msg.viewportHeight) s.vh = msg.viewportHeight
      publish()
      return
    }

    if (msg.type === "tabs") {
      const tabs = Array.isArray(msg.tabs) ? msg.tabs : []
      s.tabCount = tabs.length
      const active = tabs.find(t => t.active) || tabs[0]
      s.url = active ? active.url || "" : ""
      s.title = active ? active.title || "" : ""
      publish()
      return
    }

    if (msg.type === "frame" && msg.data) {
      // Acknowledge first so the next frame is already in flight while this one
      // is hashed and written.
      try { ws.send(JSON.stringify({ type: "ack", seq: msg.seq })) } catch {}

      // CDP keeps screencasting a still page at the full frame rate, so
      // "a frame arrived" says nothing about whether the agent is doing
      // anything. Identical pixels re-encode to identical JPEG bytes, which
      // makes a hash of the payload a cheap and honest activity signal.
      const hash = crypto.createHash("sha1").update(msg.data).digest("base64")
      if (hash === s.frameHash) return
      s.frameHash = hash
      s.latest = msg.data
      s.lastChangeAt = Date.now()
      if (msg.metadata) {
        if (msg.metadata.deviceWidth) s.vw = msg.metadata.deviceWidth
        if (msg.metadata.deviceHeight) s.vh = msg.metadata.deviceHeight
      }

      // Only the shown session's pixels reach the disk. The rest are tracked
      // for their activity dot and kept in memory in case you switch to them.
      if (shownSession() === s) {
        try { s.frame = writeFrame(msg.data) } catch { /* keep the previous frame */ }
        s.seq = msg.seq || s.seq + 1
      }
      publish()
    }
  }

  ws.onclose = () => {
    s.connected = false
    publish()
    // The daemon can outlive a single browser; retry as long as the stream file
    // is still on disk, and let the rescan handle it if it is not.
    if (sessions.get(name) === s && fs.existsSync(path.join(WATCH_DIR, `${name}.stream`))) {
      s.retry = setTimeout(() => { sessions.delete(name); scan() }, 1000)
    }
  }
  ws.onerror = () => { try { ws.close() } catch {} }
}

function drop(name) {
  const s = sessions.get(name)
  if (!s) return
  sessions.delete(name)
  if (s.retry) clearTimeout(s.retry)
  try { s.ws && s.ws.close() } catch {}
}

function scan() {
  let entries = []
  try { entries = fs.readdirSync(WATCH_DIR) } catch { entries = [] }

  const live = new Set()
  for (const entry of entries) {
    if (!entry.endsWith(".stream")) continue
    const name = entry.slice(0, -".stream".length)
    if (ONLY_SESSION !== "" && name !== ONLY_SESSION) continue
    let port
    try { port = parseInt(fs.readFileSync(path.join(WATCH_DIR, entry), "utf8").trim(), 10) } catch { continue }
    if (!Number.isFinite(port) || port <= 0) continue
    live.add(name)
    connect(name, port)
  }
  for (const name of [...sessions.keys()]) if (!live.has(name)) drop(name)
  publish()
}

// Commands from the shell. One JSON object per line.
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  let msg
  try { msg = JSON.parse(line) } catch { return }
  if (typeof msg.select === "string") select(msg.select)
})

try {
  fs.mkdirSync(WATCH_DIR, { recursive: true })
  fs.watch(WATCH_DIR, () => scan())
} catch { /* the rescan below is the fallback */ }
// Also republishes on a timer so the per-session painting dots decay without
// needing a frame to arrive.
setInterval(() => { scan() }, RESCAN_MS)
setInterval(publish, 700)
scan()

for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(sig, () => {
    for (const name of [...sessions.keys()]) drop(name)
    process.exit(0)
  })
}
