# Browser minimap

![The minimap mirroring a page an agent is driving](preview.png)

A live mirror of whatever `agent-browser` is looking at, pinned under the bar on
the focused output. It appears when a coding agent starts driving a browser and
steps aside when it stops.

## How it works

`agent-browser` runs a WebSocket screencast server per session and advertises
the port in a file:

```
$XDG_RUNTIME_DIR/agent-browser/<session>.stream    ->  e.g. 39747
```

`bridge.mjs` watches that directory, connects to every session it finds, and
prints one JSON state line per change on stdout. `Minimap.qml` spawns it through
`Process` and renders the result. Nothing polls the agent, and nothing needs the
browser to be headed — the stream works fine against a headless Chrome.

Frames arrive as base64 JPEG. The bridge writes them to
`$XDG_RUNTIME_DIR/omarchy-browser-minimap/frame-{a,b}.jpg` rather than piping
them through stdout, alternating the two names so the QML `Image` sees a URL
that actually changed. Two `Image` elements double-buffer the result: the back
one decodes off-screen and only becomes the front once it reports `Ready`. A
single `Image` with `cache: false` blanks itself between loads, which reads as a
flicker at any usable frame rate.

## When it shows and when it goes away

There is no single clean "the agent is done" signal, so three rules cover it:

1. **The page stopped changing.** After `idleHideSec` (default 8) with a still
   viewport, the minimap fades out. This is the common case: CDP stops sending
   frames entirely for a static page, so a finished navigation goes quiet within
   a second.
2. **The page never stops changing.** Live consoles, spinners and ticking clocks
   repaint forever and would otherwise pin the minimap up permanently, so
   `maxVisibleSec` (default 45) caps a single stretch of visibility.
3. **Something happened.** A navigation, or the first change after a quiet
   spell, starts a new stretch and brings it straight back.

Right-click dismisses the current stretch by hand; rule 3 still returns it.
Left-click toggles between `width` and `expandedWidth`. Closing the browser
session hides it immediately.

The bridge hashes each frame payload and drops byte-identical ones, so a
screencast that keeps ticking over an unchanged page does not read as activity.

## Settings

Panel plugins are not covered by the bar settings UI, so these are edited by
hand in the plugin's entry in `~/.config/omarchy/shell.json`:

```json
{
  "plugins": [
    { "id": "io.github.marcoripa96.browser-minimap", "width": 420, "idleHideSec": 12 }
  ]
}
```

| Key             | Default | What it does                                                        |
|-----------------|---------|---------------------------------------------------------------------|
| `fps`           | 4       | Frame rate cap, applied server-side by agent-browser                 |
| `width`         | 360     | Compact width; height follows the browser viewport's aspect ratio    |
| `expandedWidth` | 720     | Width after a left-click                                             |
| `topMargin`     | 12      | Gap below the bar                                                    |
| `rightMargin`   | 12      | Gap from the screen edge                                             |
| `showCaption`   | true    | Page title and URL above the image                                   |
| `clickThrough`  | false   | Purely ambient: never takes pointer input, cannot be clicked         |
| `monitor`       | ""      | Output name to pin to (e.g. `HDMI-A-1`); empty follows focus         |
| `idleHideSec`   | 8       | Hide after this long without a visual change; 0 disables rule 1      |
| `maxVisibleSec` | 45      | Cap on one stretch of visibility; 0 disables rule 2                  |
| `session`       | ""      | agent-browser session to pin to; empty tracks whichever is painting  |
| `debug`         | false   | Log show/hide reasoning to the `omarchy-shell` journal tag           |

Changes to `fps` and `session` restart the bridge; the rest apply live.

With two agents driving two browsers, the unpinned minimap follows whichever
page painted most recently, which means a busy page wins essentially always.
Set `session` to the name from `agent-browser session list` to pin it.

## Cost

At the default 4fps a 1440x900 viewport is roughly 150KB per changed frame,
written to tmpfs and decoded once. Raising `fps` raises both linearly, and the
decode happens inside `omarchy-shell` — worth remembering before setting it to
30.

## Installing

```bash
omarchy plugin add https://github.com/marcoripa96/omarchy-browser-minimap.git --enable
```

## Requirements

- `agent-browser` on the box (any session, headless or headed)
- a `node` runtime; `bridge.sh` probes the mise shim, `$PATH`, and `/usr/bin`

## Debugging

```bash
# What the panel sees, live:
~/.config/omarchy/plugins/io.github.marcoripa96.browser-minimap/bridge.sh \
  ~/.config/omarchy/plugins/io.github.marcoripa96.browser-minimap/bridge.mjs --fps 4

# Presence decisions (set "debug": true first):
journalctl --user -t omarchy-shell -f | grep minimap:
```
