# assets

Drop a `grandma.gif` here and `grandma` will play it (via iTerm2 `imgcat`) as the
splash each time you start a session. Without it, grandma shows a built-in ASCII
granny instead.

- File name must be exactly `grandma.gif`.
- Kept out of git (see repo .gitignore) so the repo stays light. It is local flair.
- Toggle the splash off with `GRANDMA_NO_SPLASH=1`; change the pause with
  `GRANDMA_SPLASH_SECS=0.8`.
