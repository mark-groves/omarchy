# Polkit chrome slot

First-party `omarchy.polkit` owns PAM detection, the exclusive overlay, the password field, and card geometry. Unique face (or later fingerprint) motion lives in a third-party plugin. The agent loads that plugin with one `Loader` and never hands it `flow.submit` or a `PamContext`.

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

Discovery scans enabled third-party manifests for the kind plus the card's key. The lowest plugin id wins; other eligible ids are ignored for that session. First-party manifests, disabled plugins, missing files, and a `Loader.Error` are the same empty slot.

## What the loaded item receives

The host sets `chrome` to a `QtObject` after load. Properties are value types and additive:

| Property | Type | Meaning |
| --- | --- | --- |
| `kind` | string | `"face"` or `"fingerprint"` |
| `active` | bool | animate only while the slot is shown |
| `glyph` | string | host-owned codepoint |
| `hint` | string | host-owned wording |
| `accent` | color | theme accent |
| `foreground` | color | theme text |
| `errorColor` | color | theme error |
| `errorFlash` | bool | true only during the short error fade |
| `fontFamily` | string | host UI font |
| `hintFontSize` | int | host body-small size |
| `lineWidth` | real | host hairline |
| `gap` | real | host vertical rhythm |

The item should import `QtQuick` only. It must not declare or expect `flow`, a `PamContext`, `polkitAgent`, or any way to size the card. Geometry stays first-party: extra height is applied only while a slot URL is actually resolved.

## Empty slot

When no plugin is enabled, the card stays password-sized and paints the first-party glyph and hint (`CARD.face` keeps U+F0208 and "Look at the camera"). Howdy still runs from `/etc/pam.d/polkit-1`. Missing chrome is a normal state, not a failed agent.

The published sibling is [mark-groves/omarchy-polkit-face](https://github.com/mark-groves/omarchy-polkit-face). Install with `omarchy plugin add https://github.com/mark-groves/omarchy-polkit-face --enable`. That command never uses sudo.
