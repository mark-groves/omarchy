# Visual Verification

Read this before finishing any change with a visual effect: Omarchy shell
styling and layout, panels, menus, notifications, desktop appearance,
animations, transitions, screenshots, and screen recording flows.

Visual changes must be verified in the running UI in addition to automated
tests. Creating an artifact is not sufficient: inspect it for clipping,
overlap, incorrect spacing, stale state, focus problems, and visual
regressions before finishing.

Take a full-screen screenshot without opening the editor:

```bash
omarchy capture screenshot fullscreen save
```

The command writes to Omasnap's configured screenshot directory. Use `omarchy screenshot` for the interactive capture flow, which saves and copies the capture and shows its notification. Use `omarchy screenshot --editor=overlay` to test annotation before output. Capture reference and candidate states as separate images when changing a layer-shell surface or layout, then compare both.

Record a short full-screen video for animation, transition, timing, capture, or
screen-recording changes:

```bash
omarchy screenrecord --fullscreen
# Exercise the changed behavior.
omarchy screenrecord --stop-recording
```

The stop command prints the saved video path in the configured Videos
directory. Review the recording before finishing, and keep it short and focused
on the changed behavior.

The pull request carries the evidence: put the before/after screenshots, and the recording when motion is involved, in the Screenshots section of `.github/pull_request_template.md`. `gh pr create --body` skips the template, so add that section yourself. The `Check visual evidence` workflow flags PRs touching the shell, configs, themes, or package lists that have neither captures nor a `No visible change: <reason>` line. Upload captures to the PR; never commit them.

## Checking motion frame by frame

Motion goes wrong in a frame or two, too fast to see at full speed: two texts showing at once in a crossfade, a blank frame between two panels, a card that jumps instead of morphing, a panel growing from the wrong point. Record the change and read it a frame at a time. Follow [`motion.md`](motion.md) for what the motion should be.

Run the branch's shell, not the installed one. The running shell loads plugins from `$OMARCHY_PATH`, and its launcher relaunches it if killed, so stop it and start the worktree's through Hyprland. This takes over the desktop, so tell whoever is at it first with `omarchy-notification-send` and wait a few seconds.

Put their shell back with `omarchy-restart-shell` as soon as the check is done, before you turn to anything else, and never end a turn with the worktree's shell running. While it runs, `omarchy-shell` cannot reach the desktop, so theme switches and updates fail without a word, and the user cannot tell why. `omarchy-restart-shell` stops every Omarchy shell, the worktree's included, and starts the session's own. A check usually spans several tool calls, so a `trap` in one of them does not cover it; relaunching between edits is fine, but the restore is yours to run.

```bash
WT=/path/to/worktree
while timeout 30 quickshell kill -p "$OMARCHY_PATH/shell" --any-display >/dev/null 2>&1; do :; done
hyprctl dispatch "hl.dsp.exec_cmd(\"env OMARCHY_PATH=$WT omarchy-launch-shell\")"
# A starting shell answers one ping and then drops calls while plugins load:
# wait for several answers in a row, a second apart.
OMARCHY_PATH=$WT omarchy-shell shell ping
# ... record ...
omarchy-restart-shell
```

Drive it without touching the mouse:

- A panel's own IPC target (`omarchy-shell omarchy.network open`) takes the same path as a click on its icon. `omarchy-shell shell toggle omarchy.network` takes the keybinding's path.
- `omarchy-notification-send` raises notifications, and `omarchy-shell notifications dismiss <summary>` closes one the way a click does. Requested timeouts are raised to at least 8 seconds, so don't wait on a short `-t` to see an expiry.
- `hyprctl eval "hl.dispatch(hl.dsp.cursor.move({ x = 2810, y = 70 }))"` moves the pointer for hover.
- A panel builds its content and maps its window on its first open, which can swallow the first frames of its motion. Open and close each panel once before recording unless the first open is what's being checked.

Then lay the frames out side by side. Crop to where the change happens and tile every frame of the moment, at the recording's full 60fps:

```bash
ffmpeg -ss 4.35 -t 0.4 -i recording.mp4 -vf "crop=2440:700:1400:0,scale=488:-1,tile=4x6" -frames:v 1 frames.png
```

Find the moment with a coarse sheet first (`fps=6` before the crop), then tile it at full rate and read every frame: where the motion starts from, whether anything doubles up or blanks, and where it settles.

From outside the session (an agent's shell, SSH), export `HYPRLAND_INSTANCE_SIGNATURE` and `WAYLAND_DISPLAY`. Without them `hyprctl` refuses and the recorder exits silently with nothing saved; `OMARCHY_SCREENRECORD_DEBUG=true` logs why to `$XDG_RUNTIME_DIR/omarchy-screenrecord.log`.

For interactive UI work, use `wtype` to simulate keyboard input when available.
Example: start the UI in the background, wait briefly for focus, then run
`wtype -k Right -k Return` to exercise keyboard selection and confirm the
resulting command output or state change. Prefer this over manual-only
verification when a UI returns a selected value or changes a symlink/config.

If a launched UI would otherwise remain open, keep track of its PID and stop it
after the screenshot or recording; avoid broad process kills unless checking
with `ps` first.

## Face auth surfaces

The lock, polkit and sudo face cards have a harness of their own. `omarchy-dev-face-check` drives one scenario, records the monitor, measures the card frame by frame, and prints PASS, FAIL or SKIP per target, then the run's directory.

```bash
omarchy-dev-face-check sudo match                       # lock: match|miss|match-slow|idle, polkit: match|miss|typed|cancel, sudo: match|miss|match-slow|demo
omarchy-dev-face-check lock miss --fps 120              # 120 oversamples the 60 Hz panel
omarchy-dev-face-check polkit match --shell "$WT"       # the worktree's shell for the run, then the session's again
omarchy-dev-face-check lock match --real                # the owner's face, only when they agreed and sit at the camera
```

Previews call the shell's display-only drivers (`lock previewFace`, `polkit preview`, `face-card replay`): no PAM, no camera, no keyboard. When the running shell lacks one, the check says so and falls back where it can (the sudo card to `face-card show`, the lock to its scanning-only `lock preview`, which takes the keyboard while it shows).

The targets: smooth, at least 57 presented frames a second and no frame held over 2 refreshes in every animating phase; still, every `face-probe-event` of the surface carries the same rect; prompt, the first state after the trigger is scanning within 50 ms and the card moves within 100 ms (sudo: the card is up before the verdict); brief, 0.6–1.3 s from the verdict to the card gone; cuts, no appearance or disappearance happens in one frame. RESULT is INCOMPLETE when a target could not be measured, usually because the shell logs no probe lines.

A frame counts as presented only when the card's region changed for real. The encoder refines a still picture over the frames after each change and re-codes it at key frames; counting any difference takes that residue for frames and roughly doubles the rate, so the summary prints both columns, presented and any-change.

gpu-screen-recorder, sudo and pkexec start under `systemd-run --user`: an agent's shell can carry no_new_privs, which ignores file capabilities and setuid, so gsr-kms-server records black frames ("drmfb handle is NULL") and sudo cannot start. `--real` notifies the owner first, sends one empty Enter and never a password, presses Ctrl+C if sudo asks again, warns when `sudo -n -l /usr/bin/true` shows a passwordless grant that would skip the face prompt, and refuses to lock a session that is already locked.

Runs land in `~/.cache/omarchy/face-check/<stamp>-<surface>-<scenario>/` (newest 10 kept): `check.txt`, `analysis/summary.txt` with `summary.json` and `motion.tsv`, `analysis/sheets/` and `clip.mp4`; `--keep` keeps the full recording. `omarchy-dev-face-record start|mark|stop|analyze` is the recorder underneath, for anything the scenarios do not cover: `analyze rec.mp4 --region 440x440+1380+354 --phase scan=12.5-17` takes device pixels or a layer namespace, and seconds from the first frame or `@EPOCH`.

Read the sheets to see what the numbers mean. `coarse.png` tiles the whole showing at up to 10 frames a second, to find the moment. Each `t<seconds>-<moment>.png` tiles every captured frame from 6 before to 18 after a first or last change, a phase, a probe event or a verdict, labelled with the frame number and seconds from the first frame; `held` marks a frame where the card did not change and `key` an encoder key frame. Look for where motion starts and settles, a card that shifts between states, stale content from the previous showing, and runs of `held` frames.
