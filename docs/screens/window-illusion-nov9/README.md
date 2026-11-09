# The window illusion (Nov 9 2026)

Frame sheets, ten frames a sheet at 10 fps (one sheet = one second), scaled down. `s-NN` is the
NN-th second of the recording; the app's actions start once it has connected, so the open is
around s-05, full screen in at about s-12, out at about s-17, Done at about s-20.

- `before/` — build 28's code (main 2dc9886) on the same stand-in (`mpctl serve --rounded --reshape
  --busy`): `pro-fs/` an iPhone 17 Pro, `duo-portrait-fs/` the Duo flat upright, `duo-cover-fs/`
  the Duo's cover. What to look for: the picture covering the frame from its top-left at another
  shape (text cut mid-word), two copies of the window at two sizes through a size change, a 2×
  zoomed state in full screen.
- `after/` — this build on the same sequences: `pro-fs/` (sheets `f1-NN`), `duo-portrait-fs/`,
  `duo-laptop-fs/`, `duo-side-fs/`, `duo-book-fs/`, `duo-cover-fs/`; `duo-folds/` a window in hand
  through tabletop → flat upright (s-10) → on its side (s-15) → tabletop (s-20); `duo-laptop-modes/`
  the laptop's trackpad, keyboard (up and hidden), a flip to the next window and back, the mic
  opening with words. In every frame the picture is the Mac's frame at its own shape, fitted; a
  size change is one cross-fade (one frame at 10 fps shows both); nothing covers, nothing stretches.
- `real/cover-fs/` — the real pipeline: a Debug copy of the Mac app streaming a TextEdit document
  of mine to the Duo's cover (open, full screen in, out, Done): three `watch fit to iPhone` lines
  for three deliberate changes, the window's own 48 px corners from the Mac's mask.

The numbers (shapes per action, the drag's latency, the Mac's cost, the phone's main thread) are
in CLAUDE.md, "The window illusion".
