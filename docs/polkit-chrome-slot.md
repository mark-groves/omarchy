# Polkit chrome slot

First-party `omarchy.polkit` owns PAM detection, the exclusive overlay, the password field, and card geometry. Unique face (or later fingerprint) motion is reserved for a plugin, but the agent does not instantiate plugin QML in the credential card. A loaded item under the same `BorderSurface` as `passwordInput` can walk `parent` and read the field. The card paints the first-party glyph and hint. The plugin is not handed `flow.submit` or a `PamContext`.

The plugin's files split the work:

- `PolkitAgent.qml` - Quickshell's `PolkitAgent` service, the card's two windows (`omarchy-polkit` for requests, `omarchy-polkit-preview` for the preview) and the `polkit` IPC target.
- `PolkitController.qml` - one request at a time: the flow it came on, the face lane, the field's submit rules, the probe lines and `status`.
- `PolkitCard.qml` - the pixels: scrim, card, face area, captions, field and justification pill. `PolkitCaption.qml` is one caption slot.
- `PolkitModel.js` - pure: reading the PAM stack, slot resolution, and the face lane reducer.
- `FakeFlow.qml` - the preview's scripted stand-in for `AuthFlow`.

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "markgroves.polkit-face",
  "kinds": ["service", "panel"],
  "entryPoints": {
    "service": "Service.qml",
    "panel": "Card.qml",
    "polkitFace": "FaceCardFrame.js"
  }
}
```

The slot is found by its entry point key, not by a kind. The key is taken from the first-party card table: `polkitFace` for face, `polkitFingerprint` for fingerprint. `password` has an empty key and cannot be replaced. Extra `entryPoints` keys are allowed on third-party manifests and forbidden on first-party ones. The host creates no instance for the key: whatever else the plugin declares (above, a service and panel that draw the same card on a host without this slot) loads as usual, and the slot entry is only ever evaluated as a value module.

A plugin may still declare the kind `polkit-chrome`. `computePanelEntries`, `_syncServices`, and `syncPluginWidgets` skip it, so a plugin with no other kind gets no `shell` facade and no lifetime of its own, and `omarchy plugin validate` demands a slot key from a plugin that declares it. The plugin marketplace lists only the shell's own kinds, so a published card plugin should name the key without the kind. Enablement is a `plugins[]` row either way; `omarchy plugin add` lands disabled unless `--enable` is passed.

Discovery scans enabled third-party manifests for the card's key. The lowest plugin id wins; other eligible ids are ignored for that session. First-party manifests, disabled plugins, and missing files are an empty slot. The agent may still resolve a slot URL. It does not load that URL into the card.

## Empty slot

A face card keeps its layout with no plugin: the face area holds the first-party idle mark throughout and the captions carry each state. Nothing can play a result, so a match closes the card at once and a miss goes straight back to the field. A fingerprint card stays square and paints the first-party glyph. Howdy still runs from `/etc/pam.d/polkit-1`. Missing chrome is a normal state, not a failed agent.

The published card is [mark-groves/omarchy-face](https://github.com/mark-groves/omarchy-face). Install with `omarchy plugin add https://github.com/mark-groves/omarchy-face --enable`. That command never uses sudo. On this host its own service and panel stay quiet, since the host draws the card.

## Face card paint contract

A face chrome's entry point is a JavaScript module that exports `frame(size, spec)` and `holdMs(state)`, and optionally `scanMs()`: how much of the scan to present before a fast match plays, clamped to 3 s. `FaceChrome` evaluates it and hands it only numbers: `spec` is `{ state, clock, elapsed, host }`. The module returns draw ops, which `FaceCardPainter.js` replays on a host-owned canvas as hostile input. Non-finite values are dropped; alpha, glow and line width are clamped; coordinates are bounded; ops, path commands and glow ops are capped (6000, 600 and 2000). Holds are clamped to 2 s.

The card is `FaceChrome.cardSide` (220) logical px on the lock screen and the polkit card.

`FaceChromeCanvas` asks for a frame only when its last one has landed: `frame()` and the replay run on the shell's GUI thread, the raster on Qt's canvas thread, with at most one frame in flight. `spec.clock` and `spec.elapsed` follow the wall clock from the first presented frame of a state, and pause while the card is not presenting, so a slow host skips frames rather than slowing the animation; `clock - elapsed` stays constant through a state. The sharp layer rasterises at the panel's pixel ratio. Each showing measures the raster and the JS of its frames apart, and a card over budget starts its next showing a quality level down: a smaller sharp layer scaled up on the GPU, and a bloom repainted less often. `FaceChrome.qualityLevel` remembers the level for every surface until the plugin changes.

`spec.host` is the op level the host paints. Level 1 is stroke paths, rects and vertical gradients in roles 0 (accent), 1 (text) and 2 (error). Level 2 adds:

- **Glow**: an optional trailing value on any paint op (`[0, role, alpha, width, cmds, glow]`, `[1, …, h, glow]`, `[2, …, yTo, glow]`). The op is also drawn at that alpha on a half-resolution glow layer, which two GPU `MultiEffect` blurs (a tight halo and a wide bloom) lay under the sharp strokes. `alpha` 0 with `glow` > 0 lights only the bloom. On the software scene graph there is no bloom, and glow-only ops are drawn as faint halos instead.
- **Blend**: `[3, mode]` switches later ops between normal (0) and additive "lighter" (1) compositing. Additive is ignored on a light surface.
- **Roles 3 to 5**, derived from the active theme in `FaceTheme.js`, so a theme switch recolours them: 3 is hot (the accent pushed toward the text colour), 4 is the theme palette colour furthest in hue from the accent, and 5 is the next most distinct. A theme without a usable palette gets hues rotated off its accent. The error colour is never reused.

A level-1 host ignores the trailing glow and the blend op, and paints roles above 2 in the accent, so a level-2 frame still draws there. A module that sees no `spec.host` should draw its level-1 frame.

## The face lane

`PolkitModel.pamStepsFromConfig` reads `auth` and `-auth` lines (the face module is loaded with `-auth`, so a missing module costs only the face path). A `pam_howdy.so` line inside the jump of the Ask first gate, `pam_exec.so … expose_authtok /usr/local/lib/omarchy-face/authtok-empty` with `default=N`, is started by an empty answer (trigger `ask`); one outside it scans before PAM prompts (trigger `auto`). `faceLaneTriggerFor` picks the request's lane: `ask`, `auto`, or `none` for password and fingerprint cards and whenever the lid is shut, where an empty Enter is an ordinary password answer.

The lane itself is a pure reducer, `faceLaneStep(lane, event, env)`, so whole requests are tested in node (`test/shell.d/polkit-face-test.sh`). The controller turns flow signals and card callbacks into its events and runs the effects a change asks for. On an Ask first stack:

- The card carries its face layout from the moment it opens: the face area with the idle mark, two caption slots ("Press Enter to use your face" over "or type your password"), and the field. The layout is chosen once the lid check returns (at most 200 ms, before the card fades in) and never changes during the request: nothing grows, moves or hides its space at Enter or at a result. Captions crossfade in their fixed slots.
- An empty Enter counts once the field has had focus for the prompt for 600 ms, and never from autorepeat. The accepted Enter sets the scan before `flow.submit("")`, so the first frame after it is already scanning.
- A success during the scan plays recognized: a match that beats the plugin's `scanMs()` waits for it, display only, then the plugin's hold plays and the card fades out. Keyboard and pointer go back to the desktop as soon as PAM approves.
- A failed session during the scan plays not recognized, with no shake, then returns to the field offering another try or the password. The new session's prompt is never a miss.
- A typed password goes to PAM as before; a refused one shakes the field and flashes "Wrong".

An Automatic stack scans from the start, its password prompt is the miss, and its card never sends an empty answer, which there would reach `pam_unix` as an empty password.

The card and scrim fade and grow in over 200 ms and fade out over 130 ms, on render-thread Animators. The controller follows the flow captured when the request started: Quickshell drops `polkitAgent.flow` as a request completes and emits `authenticationSucceeded` only after that.

## Preview and probes

A display-only preview plays the Ask first card from a scripted `FakeFlow` on this host's journal timings, so the card can be recorded in every state with no polkitd, PAM or camera:

```bash
omarchy-shell polkit preview match ""     # also miss, typed, cancel; "" keeps the scenario's scan time
omarchy-shell polkit preview miss 2500    # ms from the scan's start to PAM's answer (or to the Esc)
omarchy-shell polkit status               # JSON: phase, faceState, the card rect and recent states
omarchy-shell polkit hidePreview
```

Quickshell's IPC wants every argument, so the scan time is always given, as with the lock's `previewFace`. It defaults to 510 ms for a match, 4300 ms for a miss, 250 ms for a typed password and 1200 ms before a cancel. The preview runs through the same controller and card as a real request, in its own `omarchy-polkit-preview` window that never takes the keyboard, has no input region, and draws a field that takes no text; `FakeFlow.submit()` takes no answer. It is refused while a real request owns the card, and a real request ends it.

Each change of what the card shows logs one line on the shell's journal tag, `face-probe-event {"surface":"polkit" | "polkit-preview", "state":…, "t":<epoch ms>, "rect":{"x":…,"y":…,"w":…,"h":…}, "window":"omarchy-polkit" | "omarchy-polkit-preview"}`, where the state is `idle`, `scanning`, `recognized`, `notRecognized`, `password` (a card with no face lane), `closing` or `hidden`, and the rect is the card's, in its window.
