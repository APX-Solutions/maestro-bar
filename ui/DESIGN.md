# The bar, as designed

One page, shown by both apps. What it is for: recording, the review queue,
capturing a thought, and asking the company brain — from a strip that stays
out of the way at the top of the screen.

## Material

There is one surface and one ring. Everything sits on ink-coloured glass
(`#18171C` at 80%) with a 1px ring of `rgba(207,226,255,.24)` and a half-pixel
highlight along the top edge. Nothing else is outlined; hierarchy comes from
type weight and from three text colours:

| Token | Value | Used for |
| --- | --- | --- |
| text | `#EDEEF2` | titles, body, chips |
| muted | `#B2B3BA` | subtitles, idle status, icons |
| dim | `#898B91` | crumbs, counters, separators |
| accent | `#0544A9 → #022C70` | send, counts, the question bubble |
| record | `#FF453A` | the one thing that is live |

## Type

Geist, 400 and 500, shipped in `fonts/`. 12px for the interface, 13px for
what the user typed or is reading, line-height 1.6 for answers. The timer
uses tabular figures so it does not jitter.

## Layout

```
                                          ┌───┐
   ┌────────────────────────────────────┐ │ ⠿ │  drag it; it returns to an edge
   │ Review                  ‹ 1 of 3 › │ ├───┤
   │ Follow up on the Ohrid shoot       │ │ M │  open Maestro
   │ Kupola Media                       │ │ ◉ │  record audio
   │ Hi Marko, thanks for the call …    │ │ ▣ │  record the screen
   │ ✓ Done   Dismiss   Send the email  │ │ ‹ │  open and close the panel
   │                                    │ ├───┤
   │ ▤ Review 3 · ✎ Capture · ✦ Ask     │ │ ✕ │  put it away
   │ ┌────────────────────────────────┐ │ └───┘
   │ │ Tell the agent what to change  │ │  46pt
   │ └────────────────────────────────┘ │
   └────────────────────────────────────┘
```

The strip is 46pt wide — one button — and the panel is 520px beside it, both
anchored to the same top edge, so opening the panel never moves the strip. The
window follows the page: the page measures itself and sends `size` along with
where the strip's own middle sits, and that middle is what stays level with
the middle of the screen.

Folded, the panel leaves the flow entirely. That matters for more than
appearance: the window is sized to the page, and a transparent window still
swallows the clicks underneath it, so a page that stayed 600px wide would
block a column of the screen that looks empty.

The chips are the only navigation. They say where what you type goes, which
is why the composer sits directly under them and its placeholder changes with
the chip.

## Where the boldness is spent

On the recording state, and nowhere else. Idle, the strip is a column of grey
icons and says nothing. The moment a recorder is live it grows five breathing
bars and a red timer, and the button that started it goes red. Everything else
stays quiet so that one signal reads from across the room.

## Motion

Answers a person's action only: the panel collapses in 100ms, a toast rises
where the click was, the send button gives 3% on hover. The waveform is the
one thing that moves on its own, and only while recording. `prefers-reduced-
motion` stills it.

## Looking at it without the app

```
open ui/preview.html
```

That opens the review queue. For the other states, change the end of the
address in the browser: `?mock=recording` for a recording in progress,
`?mock=empty` for nothing waiting, `?mock&os=win` for Windows key labels.

`mock.js` pretends to be the native side. It is loaded by `index.html` but
does nothing unless `?mock` is in the URL.
