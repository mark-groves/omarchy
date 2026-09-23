# Polkit chrome slot

First-party `omarchy.polkit` owns PAM detection, the exclusive overlay, the password field, and card geometry. Unique face (or later fingerprint) motion is reserved for a plugin, but the agent does not instantiate plugin QML in the credential card. A loaded item under the same `BorderSurface` as `passwordInput` can walk `parent` and read the field. The card paints the first-party glyph and hint. The plugin is not handed `flow.submit` or a `PamContext`.

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "markgroves.polkit-face",
  "kinds": ["polkit-chrome"],
  "entryPoints": { "polkitFace": "PolkitFaceCard.qml" }
}
```

`polkit-chrome` is not a host-instantiated kind. `computePanelEntries`, `_syncServices`, and `syncPluginWidgets` skip it, so the plugin gets no `shell` facade and no lifetime of its own. Enablement is still a `plugins[]` row; `omarchy plugin add` lands disabled unless `--enable` is passed.

The slot key is taken from the first-party card table: `polkitFace` for face, `polkitFingerprint` for fingerprint. `password` has an empty key and cannot be replaced. Extra `entryPoints` keys are allowed on third-party manifests and forbidden on first-party ones.

Discovery scans enabled third-party manifests for the kind plus the card's key. The lowest plugin id wins; other eligible ids are ignored for that session. First-party manifests, disabled plugins, and missing files are an empty slot. The agent may still resolve a slot URL. It does not load that URL into the card.

## Empty slot

The card stays password-sized and paints the first-party glyph and hint (`CARD.face` keeps U+F0208 and "Look at the camera"), even when a `polkit-chrome` plugin is enabled. Howdy still runs from `/etc/pam.d/polkit-1`. Missing chrome is a normal state, not a failed agent.

The published sibling is [mark-groves/omarchy-polkit-face](https://github.com/mark-groves/omarchy-polkit-face). Install with `omarchy plugin add https://github.com/mark-groves/omarchy-polkit-face --enable`. That command never uses sudo.

## Face card paint contract

A face chrome's entry point is a JavaScript module that exports `frame(size, spec)` and `holdMs(state)`. `FaceChrome` evaluates it and hands it only numbers: `spec` is `{ state, clock, elapsed, host }`. The module returns draw ops, which `FaceCardPainter.js` replays on a host-owned canvas as hostile input. Non-finite values are dropped; alpha, glow and line width are clamped; coordinates are bounded; ops, path commands and glow ops are capped (6000, 600 and 2000). Holds are clamped to 2 s.

The card is `FaceChrome.cardSide` (220) logical px on the lock screen, the polkit card and the sudo face overlay.

`spec.host` is the op level the host paints. Level 1 is stroke paths, rects and vertical gradients in roles 0 (accent), 1 (text) and 2 (error). Level 2 adds:

- **Glow**: an optional trailing value on any paint op (`[0, role, alpha, width, cmds, glow]`, `[1, …, h, glow]`, `[2, …, yTo, glow]`). The op is also drawn at that alpha on a half-resolution glow layer, which two GPU `MultiEffect` blurs (a tight halo and a wide bloom) lay under the sharp strokes. `alpha` 0 with `glow` > 0 lights only the bloom. On the software scene graph there is no bloom, and glow-only ops are drawn as faint halos instead.
- **Blend**: `[3, mode]` switches later ops between normal (0) and additive "lighter" (1) compositing. Additive is ignored on a light surface.
- **Roles 3 to 5**, derived from the active theme in `FaceTheme.js`, so a theme switch recolours them: 3 is hot (the accent pushed toward the text colour), 4 is the theme palette colour furthest in hue from the accent, and 5 is the next most distinct. A theme without a usable palette gets hues rotated off its accent. The error colour is never reused.

A level-1 host ignores the trailing glow and the blend op, and paints roles above 2 in the accent, so a level-2 frame still draws there. A module that sees no `spec.host` should draw its level-1 frame.
