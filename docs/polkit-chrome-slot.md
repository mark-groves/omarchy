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
