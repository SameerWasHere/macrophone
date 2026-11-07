# Flipping between windows — what the stand-in Mac (`mpctl serve`) heard

iPhone 17 Pro simulator, paired with `mpctl serve`. Claude picked in the Dock, its window opened, then
`next, next, prev` (`MACROPHONE_WATCH_ACTIONS`), then a dictation while the second window showed,
then Done and a dictation from rest. The Dock reads Claude · Messages · Terminal · Notes · Finder · Safari.

## Before (round 3's main)

Alphabetical order (Claude → Finder → Messages), Send to changed on every flip, and every window
passed through was reshaped and put back:

```
SELECTION Claude from MP-r4-flip-and-defaults
WATCH Claude
WATCH SHAPE 1.04
SELECTION Finder from MP-r4-flip-and-defaults
WATCH WINDOW restore
WATCH Finder
WATCH SHAPE 1.04
SELECTION Messages from MP-r4-flip-and-defaults
WATCH WINDOW restore
WATCH Messages
WATCH SHAPE 1.04
SELECTION Finder from MP-r4-flip-and-defaults
WATCH WINDOW restore
WATCH Finder
WATCH SHAPE 1.04
```

## After

The Dock's order (Claude → Messages → Terminal, back to Messages), no `SELECTION` for any flip, one
`WATCH SHAPE` for the window stayed on, none for the ones passed through, the dictation to the
window on screen:

```
SELECTION Claude from MP-r4-flip-and-defaults
WATCH Claude
WATCH Messages
WATCH Terminal — claude — ~/app
WATCH Messages
WATCH SHAPE 1.04
RECEIVED #1 → Messages [medium]: Hello from.
LANDED pasted: Pasted into Messages
```

Then Done and a dictation from rest — the pick never moved:

```
SELECTION Claude from MP-r4-flip-and-defaults      (the launch's one, before the flips)
WATCH Claude
WATCH Messages
WATCH SHAPE 1.04
WATCH WINDOW restore                               (Done: the window stayed on goes back)
WATCH stopped
RECEIVED #2 → Claude [medium]: Hello from.
LANDED pasted: Pasted into Claude
```

## A freshly paired Mac

Before: `SELECTION Clipboard from MP-r4-flip-and-defaults`. After: `SELECTION Where I'm typing from
MP-r4-flip-and-defaults`, the Where I'm typing card and the Send toggle on the desktop
(`first-send-to-after.png`).
