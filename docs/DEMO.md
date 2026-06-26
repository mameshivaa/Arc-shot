# Recording a hero demo (maintainers)

The README uses `docs/assets/demo-preview.gif` as a lightweight preview. For a stronger portfolio / App Store story, replace it with a short screen recording of the real app.

## Suggested 12–20 second storyboard

1. **0–3s** — Floating launcher over desktop; toggle mic/camera if desired  
2. **3–6s** — Countdown → recording indicator  
3. **6–12s** — Open editor: timeline trim + background inspector  
4. **12–16s** — Playhead scrub with cursor/zoom visible  
5. **16–20s** — Export sheet → finished MP4 in Finder  

## Capture on macOS

```sh
# QuickTime: File → New Screen Recording
# or
screencapture -v /tmp/arcshot-demo.mov
```

## Convert to GIF for GitHub (max ~10 MB)

```sh
cd docs/assets
ffmpeg -i /path/to/demo.mov -vf "fps=12,scale=960:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" -loop 0 demo-preview.gif
```

Commit `demo-preview.gif` and keep `demo-preview.mp4` out of git (add to `.gitignore` if needed).

## Regenerate static screenshots

```sh
./Scripts/capture-app-screenshots.sh
# Copy the best frames into docs/assets/
```

Use **sanitized sample projects** — avoid real filenames or private window titles in public assets.
