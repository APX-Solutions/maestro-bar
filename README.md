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

## The sidebar

`⌃⌥M` shows and hides it. It is a strip 44 points wide that parks against the
edge of the screen. Drag it anywhere and it snaps back to the nearer side; it
remembers where you left it.

```
                                    ┌────┐
                                    │ ▤ ●│  Review, with a dot when
                                    │ ◍  │  something is waiting
                                    │ ⏺  │  Capture
                                    └────┘  Record
                                      44pt
```

Click an icon and a small flyout opens beside it. Click the same icon again, or
press Esc, and it closes. Nothing else is on screen.

```
  ┌──────────────────────────────┐┌────┐
  │ Follow up on the Ohrid shoot ││ ▤ ●│
  │ Kupola Media                 ││ ◍  │
  │                              ││ ⏺  │
  │ Hi Marko, thanks for the     │└────┘
  │ call this morning. As …      │
  │                              │
  │ ‹ ✓ … ›            3 of 11   │
  │ Tell the agent what to change│
  └──────────────────────────────┘
```

Capture is smaller still: a title, one line to type in, a microphone and a send
button.

### What the three icons do

| Icon | Reads | Buttons |
| --- | --- | --- |
| Review | `/sales/actions?status=pending` | Done, and under `…` Dismiss and Send the email |
| Capture | nothing | appends to `~/Recordings/captures.md`, with a microphone |
| Record audio | | starts and stops an audio recording |
| Record screen | | screen and audio, saved as a .mov |

Only the icon whose recording is actually running turns red. `record` in the
config takes one object or a list of them, so a third recorder is a line of
JSON.

`✓` runs the section's first action, `…` holds the rest, `‹` and `›` move
through the cards. An action fires optimistically: the card leaves at once, and
if the request fails the list reloads and a notification says so. Waiting for
the round trip makes triage feel broken.

The line at the bottom of the Review flyout is the interesting one. What you
type there does not go to a client, it POSTs to `/sales/actions/{id}/instruct`,
so you are telling the agent what to change about the card in front of you.
That endpoint already feeds the learning signals.

Capture has no endpoint yet, so it appends to a file. When there is one that
turns a note into a ticket, put its path in `compose.path` and the same box
starts posting instead. That is the only change needed.

### Sidebar configuration

```jsonc
"sidebar": {
  "enabled": true,
  "hotkey": ["ctrl", "alt", "M"],
  "edge": "right",          // which side it parks on the first time
  "width": 44,              // the strip
  "flyout_width": 330,      // what opens beside it
  "refresh_seconds": 90,    // how often the dots are refreshed
  "record": { "symbol": "record.circle", "mode": "audio", "label": "Record" },
  "sections": [ { ... } ]   // one icon each, in order
}
```

A section:

| Key | Meaning |
| --- | --- |
| `id` | Sent as `section` with anything the compose box posts |
| `title` | The icon's tooltip, and the heading of a compose flyout |
| `symbol` | SF Symbol name for the icon |
| `list` | Endpoint returning the cards; empty means a compose only flyout |
| `fields` | Which keys of a row to read for `title`, `subtitle`, `body`, in order of preference |
| `actions` | The buttons. First one is `✓`, the rest go under `…` |
| `compose` | The line to type in at the bottom |

An action:

```json
{ "label": "Done", "symbol": "checkmark", "method": "PATCH",
  "path": "/sales/actions/{id}", "body": { "status": "done" },
  "advance": true, "toast": "Marked done" }
```

`{id}` becomes the row's id and `{any_other_field}` becomes that field of the
row, so an action can address a nested resource. `advance` false keeps the card
on screen after the request.

A compose box:

```json
{ "path": "/sales/actions/{id}/instruct", "field": "instruction",
  "placeholder": "Tell the agent what to change", "record": false, "toast": "Sent" }
```

`field` is the JSON key your text goes into. `section` and `item_id` are added
automatically. With `path` empty and `file` set, the text is appended to that
file instead. `record` true adds the microphone button.

Adding a fourth icon, for meeting tasks, is a section with
`"list": "/meeting-tasks?status=proposed"` and two actions pointing at
`/meeting-tasks/{id}/accept` and `/meeting-tasks/{id}/dismiss`. No rebuild.

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
