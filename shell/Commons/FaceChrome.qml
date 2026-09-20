pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Loads a third-party face chrome plugin's paint module and exposes it as two
// pure functions. One instance serves every face-scan surface, so polkit and
// the lock screen paint the same card from the same module.
//
// The plugin is handed nothing. Not an Item, not a window, not a drawing
// context, not a QtObject belonging to the shell, not even the theme. It
// receives three values and returns numbers.
//
// That is the whole isolation story, and it is narrow on purpose. Measured on
// Quickshell 0.3.1 / Qt 6.11.2, every softer boundary leaks: a plugin Item
// under a credential surface reaches the password field; a Loader reaches it
// even when it loads a non-Item QtObject, because the loader still injects a
// scope `parent`; a detached Item used as a ShaderEffectSource reaches it,
// because being a source attaches the host window; and a 2D context reaches it
// through `ctx.canvas`. Only numbers can safely cross.
//
// Known residual: the module is evaluated in the shell's JS engine, so it can
// see the `Qt` namespace and it is not preempted. A hostile plugin cannot read
// the password field, but it could spin and stall the shell. Moving evaluation
// to a WorkerScript would fix that at the cost of an async frame path.
QtObject {
  id: root

  // file:// URL of the plugin's entry point, resolved by the host registry.
  property string sourceUrl: ""

  // The host registry. Lock and the shell bind this so the card loads even
  // when polkit has never shown a face dialog. Discovery matches
  // PolkitModel.resolveChromeSlot("face"): enabled third-party
  // `polkit-chrome` with a `polkitFace` entry, lowest id wins.
  property var pluginRegistry: null

  property var api: null
  property string failure: ""
  property int revision: 0

  readonly property bool ready: api !== null

  onSourceUrlChanged: {
    api = null
    failure = ""
    if (sourceUrl === "") pluginFile.path = ""
    else pluginFile.path = root.pathFor(sourceUrl)
  }

  onPluginRegistryChanged: bindFromRegistry(pluginRegistry)

  Connections {
    target: root.pluginRegistry
    function onRegistryRevisionChanged() { root.bindFromRegistry(root.pluginRegistry) }
    function onPluginsChanged() { root.bindFromRegistry(root.pluginRegistry) }
  }

  function urlFromRegistry(registry) {
    if (!registry || !registry.installedPlugins) return ""
    var plugins = registry.installedPlugins
    var eligible = []
    var id
    for (id in plugins) {
      var manifest = plugins[id]
      if (!manifest || typeof manifest !== "object") continue
      if (manifest.__isFirstParty) continue
      if (!Array.isArray(manifest.kinds) || manifest.kinds.indexOf("polkit-chrome") === -1) continue
      if (!manifest.entryPoints || typeof manifest.entryPoints.polkitFace !== "string") continue
      if (!manifest.entryPoints.polkitFace) continue
      if (typeof registry.isEnabled !== "function" || !registry.isEnabled(id)) continue
      var url = typeof registry.entryPointUrl === "function" ? registry.entryPointUrl(manifest, "polkitFace") : ""
      if (!url) continue
      eligible.push({ id: id, url: url })
    }
    if (!eligible.length) return ""
    eligible.sort(function(a, b) {
      if (a.id < b.id) return -1
      if (a.id > b.id) return 1
      return 0
    })
    return eligible[0].url
  }

  // Point the shared loader at the installed face chrome plugin. Surfaces
  // call this; they do not wait for a polkit prompt to have resolved a slot.
  function bindFromRegistry(registry) {
    var url = root.urlFromRegistry(registry)
    if (url === root.sourceUrl) return
    root.sourceUrl = url
  }

  function pathFor(url) {
    var s = String(url || "")
    if (s.indexOf("file://") === 0) s = s.substring(7)
    try {
      return decodeURIComponent(s)
    } catch (e) {
      return s
    }
  }

  function install(text) {
    var src = String(text || "")
    if (src.length === 0) {
      root.reject("empty")
      return
    }

    // `.pragma library` is a QML directive, not JavaScript, so it has to go
    // before the module is evaluated as a plain function body.
    src = src.replace(/^\s*\.pragma\s+library\s*$/m, "")

    var built = null
    try {
      // Function, not eval: the module body cannot capture anything local to
      // this file, so it has no path to `root`, the FileView, or the registry.
      var factory = new Function(
        src + "\nreturn { frame: typeof frame === 'function' ? frame : null,"
        + " holdMs: typeof holdMs === 'function' ? holdMs : null };")
      built = factory()
    } catch (e) {
      root.reject("did not evaluate: " + e)
      return
    }

    if (!built || !built.frame || !built.holdMs) {
      root.reject("does not export frame() and holdMs()")
      return
    }

    root.api = built
    root.failure = ""
    root.revision++
    console.log("face chrome loaded:", root.sourceUrl)
  }

  function reject(why) {
    root.api = null
    root.failure = why
    root.revision++
    console.warn("face chrome rejected,", why + ":", root.sourceUrl)
  }

  // One frame of draw ops, or an empty list. A plugin that throws is dropped
  // rather than retried every repaint, so a broken plugin degrades to the
  // first-party glyph instead of spamming the journal at 60 Hz.
  function frame(size, state, clock, elapsed) {
    if (!root.api) return []
    try {
      var ops = root.api.frame(size, { state: state, clock: clock, elapsed: elapsed })
      return ops && ops.length !== undefined ? ops : []
    } catch (e) {
      root.reject("threw while painting: " + e)
      return []
    }
  }

  // How long the host holds a result before tearing the card down. Clamped:
  // the plugin declares its own timing, but it does not get to pin a
  // credential dialog open.
  function holdMs(state) {
    if (!root.api) return 0
    var ms = 0
    try {
      ms = Number(root.api.holdMs(state))
    } catch (e) {
      root.reject("threw while reporting timing: " + e)
      return 0
    }
    if (!isFinite(ms) || ms <= 0) return 0
    return Math.min(ms, 2000)
  }

  property FileView pluginFile: FileView {
    id: pluginFile
    path: ""
    watchChanges: true
    printErrors: false
    onLoaded: root.install(text())
    onLoadFailed: root.reject("unreadable")
    onFileChanged: reload()
  }
}
