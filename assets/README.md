# assets

Two files, both tracked, both animated, both with a **transparent background** so the art
sits on whatever is behind it rather than carrying a box of its own.

`grandma-mascot.gif` is the README header, 440x440, shown at width 280. Transparency is
what makes it work in GitHub light and dark without shipping two files or a `<picture>`
element: there is no background to match, so there is nothing to get wrong. The browser
scales 440 down to 280, which softens the edges that a GIF's 1-bit alpha would otherwise
leave hard.

`grandma.gif` is the terminal splash, 260x260, played by `imgcat` or `chafa` when the
terminal has a real image protocol. Same reason for transparency here: it blends into the
user's own colour scheme instead of stamping a black square on a light terminal. Kept small
on purpose, because `imgcat` pushes the whole file through the tty on every launch.

- The splash filename must be exactly `grandma.gif`. Without it, grandma draws the built-in
  typographic wordmark instead.
- Toggle the splash off with `GRANDMA_NO_SPLASH=1`; change the pause with
  `GRANDMA_SPLASH_SECS=0.8`.

Rebuilding them from a high-resolution source: crop to the subject's alpha bounding box,
scale with lanczos, then a per-file palette via `palettegen` with `reserve_transparent=1`
and `paletteuse` with `alpha_threshold=128`. Frame rate is the size lever, 8fps for the
header and 12 for the splash. Do not flatten onto a colour, and do not raise the frame rate
without checking what it does to the byte count.
