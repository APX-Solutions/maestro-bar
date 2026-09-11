# Maestro Bar

A small native macOS app for Maestro. Two parts:

- a **menu bar item** for recording and one click commands
- a **floating panel** that a hot key summons anywhere on screen, for working
  through the queue that is waiting for you and for capturing an idea before it
  evaporates

Neither is written in Swift in the sense that matters. The menu, the panel, the
sections, the buttons and the endpoints all come from `maestro-bar.json`.
Adding a button is editing JSON, not rebuilding the app.

## Install

On your own machine, or handing it to someone else:

```sh
./install.sh
```

That does everything below and a bit more. `INSTALL.md` is the short version
written for someone receiving this folder for the first time.

## Build by hand

Needs the Xcode command line tools (`xcode-select --install`) and, for audio,
ffmpeg (`brew install ffmpeg`).

```sh
cd ~/Desktop/MaestroBar
./build.sh              # builds MaestroBar.app here
./build.sh install      # also copies it to /Applications and starts it
./build.sh login        # also starts it automatically at login
```

Put the API token in the login keychain once:

```sh
security add-generic-password -s maestro-token -a "$USER" -w 'YOUR_TOKEN'
```

The first recording asks for the Microphone permission, screen recording asks
for Screen Recording. Both prompts come from macOS and are granted once.

## The bar

`⌘M` shows and hides it. It parks against the right edge of the screen, level
with the middle: a strip one button wide, with the panel shut. Click the
chevron to open the panel beside it, for the queue, for capturing a thought
and for asking the company brain.

```
                                          ┌───┐
   ┌────────────────────────────────────┐ │ ⠿ │  drag it; it returns to an edge
   │ Review                  ‹ 1 of 3 › │ ├───┤
   │ Follow up on the Ohrid shoot       │ │ ◉ │  record audio
   │ Kupola Media                       │ │ ▣ │  record the screen
   │ Hi Marko, thanks for the call …    │ │ ‹ │  open and close the panel
   │ ✓ Done   Dismiss   Send the email  │ ├───┤
   │                                    │ │ ✕ │  put it away
   │ ▤ Review 3 · ✎ Capture · ✦ Ask     │ └───┘
   │ ┌────────────────────────────────┐ │  46pt
   │ │ Tell the agent what to change  │ │
   │ └────────────────────────────────┘ │
   └────────────────────────────────────┘
```

Idle, the strip says nothing at all. While a recording runs it shows a timer
and the button that started it turns red.

Drag the grip to move it; dropped anywhere it returns to the nearer edge, and
where you leave it is where it comes back. The chevron opens and closes the
panel, and the bar always comes back with it shut. `×` puts the whole thing
away, and so does Escape twice.

Everything on screen is one web page, in `ui/`, shared with the Windows app —
so the two look identical and are edited once. `ui/DESIGN.md` says why it looks
the way it does. To look at it without building anything:

```sh
open ui/preview.html
```

### What the chips do

| Chip | Reads | Buttons |
| --- | --- | --- |
| Review | `/sales/actions?status=pending` | Done, Dismiss, Send the email |
| Capture | nothing | appends to `~/Recordings/captures.md`, with a microphone |
| Ask | `/brain/ask` | answers with citations you can click |

The two buttons in the strip start and stop a recording — audio, and screen with
audio. Only the one that is running turns red, and the strip counts up while it
does. `record` in the config takes one object or a list of them, so a third
recorder is a line of JSON.

The box at the bottom belongs to whichever chip is lit, and its placeholder
says so. Under Review what you type does not go to a client: it POSTs to
`/sales/actions/{id}/instruct`, so you are telling the agent what to change
about the card in front of you. That endpoint already feeds the learning
signals. Under Ask it goes to the company brain and the answer comes back with
its sources.

Capture has no endpoint yet, so it appends to a file. When there is one that
turns a note into a ticket, put its path in `compose.path` and the same box
starts posting instead. That is the only change needed.

### Keeping the bar out of a screen share

By default the bar is on screen like any other window: people you share with
see it, and it is in Maestro's own screen recordings.

`"invisible": true` in the config hides it from capture — the same mechanism
Zoom uses for its own overlays — so it stays on your screen and appears in
nobody else's. Worth turning on for client calls, where your queue is not
their business, and leaving off the rest of the time.

### Configuration

```jsonc
"sidebar": {
  "enabled": true,
  "hotkey": ["cmd", "M"],
  "refresh_seconds": 90,      // how often the counts are refreshed
  "invisible": false,         // true hides it from screen shares
  "ask_path": "/brain/ask",   // empty removes the Ask chip
  "ask_placeholder": "Ask about clients, meetings, decisions",
  "record": { "symbol": "record.circle", "mode": "audio", "label": "Record" },
  "sections": [ { ... } ]     // one chip each, in order
}
```

A section:

| Key | Meaning |
| --- | --- |
| `id` | Sent as `section` with anything the compose box posts |
| `title` | The chip's label |
| `symbol` | SF Symbol name; the page maps it onto its own drawn set |
| `list` | Endpoint returning the cards; empty means a compose-only chip |
| `fields` | Which keys of a row to read for `title`, `subtitle`, `body`, in order of preference |
| `actions` | The buttons under a card. The first one is the primary |
| `compose` | The box at the bottom |

An action:

```json
{ "label": "Done", "symbol": "checkmark", "method": "PATCH",
  "path": "/sales/actions/{id}", "body": { "status": "done" },
  "advance": true, "toast": "Marked done" }
```

`{id}` becomes the row's id and `{any_other_field}` becomes that field of the
row, so an action can address a nested resource. `advance` false keeps the card
on screen after the request. An action fires optimistically: the card leaves at
once, and if the request fails the list reloads and the bar says so. Waiting for
the round trip makes triage feel broken.

A compose box:

```json
{ "path": "/sales/actions/{id}/instruct", "field": "instruction",
  "placeholder": "Tell the agent what to change", "record": false, "toast": "Sent" }
```

`field` is the JSON key your text goes into. `section` and `item_id` are added
automatically. With `path` empty and `file` set, the text is appended to that
file instead. `record` true puts a Voice button in the box.

Adding a fourth chip, for meeting tasks, is a section with
`"list": "/meeting-tasks?status=proposed"` and two actions pointing at
`/meeting-tasks/{id}/accept` and `/meeting-tasks/{id}/dismiss`. No rebuild.

### Editing the interface

`ui/` is copied into the app bundle at build time, and the app prefers
`~/Desktop/MaestroBar/ui/index.html` when it exists — so on this machine you can
edit the page and reopen the bar without rebuilding. `scripts/sync-ui.sh` copies
it to the Windows checkout, which is how the two stay identical.

## The menu bar

`M` when idle, `M 3` if the badge is on and three things are waiting, and
`● 1:24` in red while recording, counting up. The timer is driven by the
recording process itself, so it cannot drift out of sync with reality.

| `type` | Fields | What it does |
| --- | --- | --- |
| `panel` | | Opens the floating panel |
| `record` | `mode` (`audio` or `screen`), `hotkey` | Starts and stops a recording |
| `clients` | `mode` | Submenu of clients; tags the recording with the one you pick |
| `shell` | `cmd` | Runs a shell command |
| `open` | `url` | Opens a URL |
| `post` | `path`, `body`, `toast` | POSTs to the API with your token |
| `separator` | | A dividing line |

Hotkeys are declared in the JSON, for example `["ctrl","alt","R"]`. Modifiers
are `cmd`, `alt`, `ctrl`, `shift`, and at least one is required. Avoid
`⌃Space` and `⌃⌥Space`: macOS uses both for switching input source, which
matters when you keep a Cyrillic and a Latin keyboard.

## Recording

```sh
ffmpeg -f avfoundation -list_devices true -i ""
```

Use the index of the input you want in `audio_device`. To capture both sides of
a call, build an Aggregate Device in Audio MIDI Setup containing your microphone
and BlackHole and point at that.

`after_record.cmd` runs when the file closes, with `{file}` and `{client}`
substituted and already quoted:

```json
"after_record": { "cmd": "~/Desktop/rec/transcribe.sh {file}", "notify": true }
```

That is where the loop closes: point it at a script that transcribes and then
posts the text, and a brainstorm becomes a ticket without anyone retyping it.

## Where the config is read from

The first file that exists wins:

1. `~/.config/maestro/bar.json`
2. `~/Desktop/MaestroBar/maestro-bar.json`
3. `~/Desktop/rec/maestro-bar.json`

The path actually used is shown greyed out at the bottom of the menu, and
"Reload config" applies edits without restarting.
