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
import { execFile } from "node:child_process"
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
// A hard allowlist: the bridge never even connects to anything else. Accepts
// several names, comma separated, which is how you keep the minimap scoped to
// the agents you want mirrored — useful when one of the sessions on the box is
// working on something you would rather not have on screen. Distinct from the
// soft `select` below, which chooses among the sessions it is watching.
const ONLY_SESSIONS = flag("--session", "")
  .split(",")
  .map(name => name.trim())
  .filter(name => name !== "")
// Resolving where a click landed costs one read-only query per action. Off,
// the bridge never issues a command of any kind into a session.
const TRACK_POINTER = args.indexOf("--track") !== -1

// agent-browser is not necessarily on the PATH the shell inherited.
const CLI = (() => {
  const candidates = [
    `${process.env.HOME}/.local/share/mise/shims/agent-browser`,
    "/usr/local/bin/agent-browser",
    "/usr/bin/agent-browser",
  ]
  for (const c of candidates) { try { fs.accessSync(c, fs.constants.X_OK); return c } catch {} }
  return "agent-browser"
})()
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

// Actions are events, not state: two identical ones in a row are two things
// that happened, so they bypass the deduplication above and do not disturb it.
function emitAction(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n")
}

const SHORT = 40
function short(value) {
  const text = String(value == null ? "" : value).replace(/\s+/g, " ").trim()
  return text.length > SHORT ? text.slice(0, SHORT - 1) + "\u2026" : text
}

function quoted(value) {
  return "\u201c" + short(value) + "\u201d"
}

// Playwright-style selector engines carry human text inside the selector
// string itself, so a plain `click` command is often still describable
// without asking the page anything.
function fromSelector(selector, refs) {
  const text = String(selector || "")
  let m = text.match(/^(?:text|:has-text)=["']?(.+?)["']?$/i)
  if (m) return quoted(m[1])
  m = text.match(/^role=([a-z]+)\[name=["']?(.+?)["']?\]$/i)
  if (m) return m[1] + " " + quoted(m[2])
  m = text.match(/^role=([a-z]+)$/i)
  if (m) return m[1]
  // A snapshot ref means nothing to a reader on its own, but the snapshot that
  // minted it said what it was.
  const ref = text.match(/^@(.+)$/)
  if (ref) {
    const known = refs && refs[ref[1]]
    if (known && known.name) return (known.role ? short(known.role) + " " : "") + quoted(known.name)
    if (known && known.role) return short(known.role)
    return "element"
  }
  return short(text)
}

// What the agent aimed at, in the words a person would use. agent-browser's
// locator commands carry the text, role or label they searched by, which is
// most of what an agent actually clicks — bare CSS selectors and snapshot refs
// are the cases with nothing human in them.
function targetOf(action, p, refs) {
  switch (action) {
    case "getbytext": return quoted(p.text)
    case "getbyrole": return p.name ? short(p.role) + " " + quoted(p.name) : short(p.role)
    case "getbylabel": return quoted(p.label)
    case "getbyplaceholder": return quoted(p.placeholder)
    case "getbyalt": return quoted(p.alt)
    case "getbytitle": return quoted(p.title)
    case "getbytestid": return short(p.testId)
    default: return fromSelector(p.selector, refs)
  }
}

// fill and type carry the value being typed. It is never shown: this is where
// passwords and tokens go, and the panel sits on a desktop.
// Actions worth drawing a pointer for: things done *at* a place on the page.
const POINTED = new Set(["click", "dblclick", "hover", "drag", "check", "uncheck", "focus", "select", "fill", "type"])

const VERBS = {
  click: "click", dblclick: "double-click", hover: "hover", focus: "focus",
  check: "check", uncheck: "uncheck", select: "select", fill: "type into",
  type: "type into", upload: "upload to", drag: "drag", scrollintoview: "scroll to",
}

function verbFor(name, fallback) {
  return VERBS[String(name || "").toLowerCase()] || fallback
}

// A short human label for one agent action.
function describe(action, p, refs) {
  // The locator family: the verb is in `subaction`, the target in the params.
  if (action.indexOf("getby") === 0) {
    const verb = p.subaction ? verbFor(p.subaction, String(p.subaction)) : "find"
    return verb + " " + targetOf(action, p, refs)
  }

  switch (action) {
    case "navigate": {
      let url = String(p.url || "")
      url = url.replace(/^https?:\/\//, "").replace(/\/$/, "")
      return "navigate " + short(url)
    }
    case "click": return "click " + fromSelector(p.selector, refs)
    case "dblclick": return "double-click " + fromSelector(p.selector, refs)
    case "hover": return "hover " + fromSelector(p.selector, refs)
    case "focus": return "focus " + fromSelector(p.selector, refs)
    case "check": return "check " + fromSelector(p.selector, refs)
    case "uncheck": return "uncheck " + fromSelector(p.selector, refs)
    case "select": return "select " + fromSelector(p.selector, refs)
    case "scrollintoview": return "scroll to " + fromSelector(p.selector, refs)
    case "drag": return "drag " + fromSelector(p.selector, refs)
    case "upload": return "upload to " + fromSelector(p.selector, refs)
    // Deliberately no value: this is where credentials get typed.
    case "type": return "type into " + fromSelector(p.selector, refs)
    case "fill": return "type into " + fromSelector(p.selector, refs)
    case "keyboard": return "type"
    case "press": return "press " + short(p.key || "")
    case "scroll": {
      const arrows = { up: "\u2191", down: "\u2193", left: "\u2190", right: "\u2192" }
      const arrow = arrows[String(p.direction || "").toLowerCase()] || ""
      return "scroll " + arrow + (p.amount !== undefined ? String(p.amount) : "")
    }
    case "mousemove": return "move " + Math.round(p.x) + "," + Math.round(p.y)
    case "mousedown": return "mouse down"
    case "mouseup": return "mouse up"
    case "wheel": return "wheel"
    case "back": return "back"
    case "forward": return "forward"
    case "reload": return "reload"
    case "screenshot": return "screenshot"
    case "snapshot": return "snapshot"
    case "eval": return "eval"          // never the code itself
    case "waitfor":
    case "wait": return "wait " + (p.selector ? fromSelector(p.selector, refs) : short(p.ms || ""))
    default: return short(action)
  }
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

  // Covers automatic switches as well as deliberate ones: whichever way the
  // shown session changed, its picture is rewritten before it is announced.
  if (s.name !== shownName) refreshShown(s)
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

// The two frame slots are shared by every session, so a session's stored path
// can be holding some other session's picture by the time you come back to it.
// Whenever the shown session changes, its own last frame is written afresh —
// that also means switching shows the page immediately instead of waiting for
// it to repaint. A session that has never painted reports no frame at all,
// which is the one case where the panel should go blank rather than keep
// showing what was there before.
function refreshShown(s) {
  if (!s) return
  if (!s.latest) { s.frame = ""; return }
  try {
    s.frame = writeFrame(s.latest)
    s.seq = (s.seq || 0) + 1
  } catch {}
}

function select(name) {
  const next = typeof name === "string" ? name : ""
  if (next === selected) return
  selected = next
  // publish() refreshes the frame whenever the shown session changes, so a
  // manual switch needs nothing extra here.
  publish()
}

// Only refs and plain CSS can be resolved this way. Playwright's text= and
// role= engines are not accepted by `get box`, and the getby* locator commands
// carry no selector at all, so those actions are named in the feed but never
// drawn.
function resolvable(selector) {
  const text = String(selector || "")
  if (text === "") return false
  if (text.charAt(0) === "@") return true
  return text.indexOf("=") === -1
}

// One query in flight per session: an agent working quickly should not spawn a
// process per action faster than they can complete.
function locate(s, selector) {
  if (!TRACK_POINTER || s.locating || !resolvable(selector)) return
  s.locating = true
  execFile(CLI, ["get", "box", selector, "--json"],
    { env: { ...process.env, AGENT_BROWSER_SESSION: s.name }, timeout: 2000 },
    (err, stdout) => {
      s.locating = false
      if (err) return
      let parsed
      try { parsed = JSON.parse(stdout) } catch { return }
      const box = parsed && parsed.success && parsed.data
      if (!box || typeof box.x !== "number" || typeof box.y !== "number") return
      // The centre of the element is where a click is aimed.
      emitAction({
        type: "point",
        session: s.name,
        x: box.x + (box.width || 0) / 2,
        y: box.y + (box.height || 0) / 2,
      })
    })
}

function connect(name, port) {
  const existing = sessions.get(name)
  if (existing && existing.port === port) return
  if (existing) drop(name)

  const s = {
    name, port, connected: false, tabCount: 0,
    url: "", title: "", frame: "", latest: "", seq: 0, vw: 0, vh: 0,
    lastChangeAt: 0, frameHash: "", refs: {}, locating: false, ws: null, retry: null,
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

    // An agent works by taking a snapshot and then clicking the refs it
    // returned. The snapshot's result carries the whole ref table — name and
    // role for each — and it is broadcast to us too, so "click @e5" can be
    // reported as the thing it actually clicked rather than as "@e5".
    if (msg.type === "result" && msg.action === "snapshot"
        && msg.data && msg.data.refs && typeof msg.data.refs === "object") {
      s.refs = msg.data.refs
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

    // agent-browser broadcasts every command it runs to passive stream
    // clients, so the feed costs nothing but parsing: no polling, no commands
    // issued back into a session an agent is in the middle of driving.
    if (msg.type === "command" && msg.action) {
      const p = msg.params || {}
      // Our own box queries come back round the stream; they are plumbing, not
      // something the agent did.
      if (msg.action === "boundingbox") return
      const event = {
        type: "action",
        session: name,
        action: msg.action,
        label: describe(msg.action, p, s.refs),
      }
      // Only raw pointer commands carry coordinates; selector-driven ones,
      // which is most of what an agent does, have no spatial information.
      if (typeof p.x === "number" && typeof p.y === "number") {
        event.x = p.x
        event.y = p.y
      }
      emitAction(event)

      if (typeof p.x === "number" && typeof p.y === "number") {
        emitAction({ type: "point", session: name, x: p.x, y: p.y })
      } else if (POINTED.has(msg.action)) {
        locate(s, p.selector)
      }
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
    if (ONLY_SESSIONS.length > 0 && ONLY_SESSIONS.indexOf(name) === -1) continue
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

// Nothing of this should outlive the process. The frames are the only thing
// the plugin writes anywhere, and leaving them behind would mean an uninstall
// left a directory of screenshots sitting in the runtime tree until reboot.
function cleanUp() {
  for (const name of [...sessions.keys()]) drop(name)
  try {
    for (const f of fs.readdirSync(OUT_DIR)) fs.unlinkSync(path.join(OUT_DIR, f))
    fs.rmdirSync(OUT_DIR)
  } catch {}
}

for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(sig, () => { cleanUp(); process.exit(0) })
}
process.on("exit", cleanUp)
