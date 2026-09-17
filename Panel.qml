import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget + click-open panel for Dotstate. Shows the sync state written
// by backup.sh (see ../backup.sh) and offers quick actions.
//
// IMPORTANT: `omarchy plugin add` clones this repo into its own directory
// under ~/.config/omarchy/plugins/<id>/, separate from wherever you keep
// your actual working dotfiles checkout (the one with your real home/ and
// packages/, where install.sh/backup.sh actually run). This widget can't
// assume it lives inside that checkout, so the path is a per-instance
// setting (dotfilesRepo) instead of being inferred. Until it's set, the
// panel shows a guided setup flow (create-from-template link, clone URL +
// target dir, "Clone & set up") that clones the real checkout and runs its
// install.sh for the user - no terminal command required to get going.
// Saving the path (whether via that flow or by hand) persists it inline in
// ~/.config/omarchy/shell.json via bar.shell.updateEntryInline(). There is
// no separate "settings" UI for third-party widgets in Setup > Plugins as
// of this Omarchy version, so the panel has to own this itself.
Panel {
  id: root
  moduleName: "io.github.marcmeier.dotstate"
  ipcTarget: "io.github.marcmeier.dotstate"
  manageIpc: false

  readonly property string rawRepoDir: String(setting("dotfilesRepo", ""))
  readonly property string repoDir: rawRepoDir.replace(/^~/, Quickshell.env("HOME"))
  readonly property bool configured: repoDir !== ""
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 10, 3600)
  readonly property string statusPath: Quickshell.env("HOME") + "/.cache/dotstate/status.json"

  // The Omarchy plugin clone (~/.config/omarchy/plugins/<id>/) is throwaway
  // infrastructure Omarchy can update or delete on its own - it must never
  // double as "the" dotfiles repo. Pointing dotfilesRepo at it (or at
  // anything under it) has, in practice, ended with every synced config
  // pointing into a directory that then vanished. Refused here the same way
  // install.sh's guard_not_plugin_checkout refuses it on the CLI side.
  readonly property string pluginsDirPrefix: Quickshell.env("HOME") + "/.config/omarchy/plugins/"

  function isPluginCheckoutPath(expandedPath) {
    return (String(expandedPath || "") + "/").indexOf(root.pluginsDirPrefix) === 0
  }

  property var status: Model.defaultStatus()
  property bool syncing: false
  property string pathError: ""
  property string cloneUrl: ""
  property string cloneTargetDir: "~/Projects/dotfiles"
  property bool showManualPath: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)

  readonly property color iconColor: {
    if (!configured || !status.known) return dim
    if (!status.ok) return urgent
    return foreground
  }

  readonly property string tooltipText: {
    if (!configured) return "Dotstate: not set up yet - click to get started"
    if (!status.known) return "Dotstate: no sync run yet - click Sync now"
    var when = Model.relativeTime(status.lastRun)
    if (!status.ok) return "Dotstate: last sync failed " + when + (status.error ? " (" + status.error + ")" : "")
    if (status.dirty) return "Dotstate: synced " + when + ", but local changes remain"
    return "Dotstate: synced " + when
  }

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function refresh() {
    statusFile.reload()
  }

  // Persists dotfilesRepo inline into this widget's own bar.layout entry in
  // ~/.config/omarchy/shell.json, the same mechanism Power/Tailscale/Clock
  // use for their own per-instance settings (see shell/shell.qml's
  // updateEntryInline - it replaces the entry with {id, ...settings}, so the
  // full settings object must be passed, not just the changed key).
  // Returns an error string if `path` (as typed, ~-relative or absolute)
  // must be refused, or "" if it's fine to save/clone into.
  function validateRepoPath(path) {
    var trimmed = String(path || "").trim()
    if (trimmed === "") return ""
    var expanded = trimmed.replace(/^~/, Quickshell.env("HOME"))
    if (root.isPluginCheckoutPath(expanded)) {
      return "That's this plugin's own checkout, not your working dotfiles repo - " +
             "point this at where you cloned your actual repo (e.g. ~/Projects/dotfiles)."
    }
    return ""
  }

  function saveDotfilesRepo(path) {
    var trimmed = String(path || "").trim()
    var error = validateRepoPath(trimmed)
    root.pathError = error
    if (error !== "") return
    if (trimmed === rawRepoDir) return
    var next = Object.assign({}, root.settings, { dotfilesRepo: trimmed })
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, next)
    }
  }

  function syncNow() {
    if (!configured || syncProc.running) return
    syncing = true
    syncProc.command = ["systemctl", "--user", "start", "dotstate-backup.service"]
    syncProc.running = true
  }

  // Best-effort: opens a floating terminal, matching the pattern first-party
  // widgets use (see SystemUpdate.qml's
  // "omarchy-launch-floating-terminal-with-presentation" call). Verify this
  // renders as expected on a real Omarchy session - it wasn't runnable from
  // where this plugin was authored. Used (instead of a backgrounded Process)
  // for anything that may need sudo (install.sh's pacman calls) or git
  // credential prompts (cloning a private repo over https/ssh) - both need a
  // real TTY the user can answer, which this gives them without them having
  // to know to open a terminal themselves.
  function runShellInFloatingTerminal(shellCmd) {
    if (!root.bar) return
    var cmd = "bash -lc " + Util.shellQuote(shellCmd)
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
  }

  function runInFloatingTerminal(scriptName) {
    if (!configured) return
    var inner = "cd " + Util.shellQuote(repoDir) + " && ./" + scriptName + "; echo; read -n1 -p 'Press any key to close'"
    runShellInFloatingTerminal(inner)
  }

  // Opens GitHub's "generate from template" page directly, so a brand-new
  // user never has to be told what "use this template" means or hunt for
  // the button themselves.
  function openTemplatePage() {
    Quickshell.execDetached(["xdg-open", "https://github.com/marcmeier/Dotstate/generate"])
  }

  // Full guided setup in one click: clones the repo the user just created
  // from the template (or already has), then immediately runs its
  // install.sh in the same terminal - the same two steps the README's
  // Quickstart asks for by hand, run for the user instead. Saves the
  // resulting path as dotfilesRepo right away so the panel can switch into
  // its normal "configured" state without the user typing that path
  // anywhere themselves.
  function cloneAndSetup() {
    var url = String(root.cloneUrl || "").trim()
    var dir = String(root.cloneTargetDir || "").trim()
    if (url === "" || dir === "") return
    var error = validateRepoPath(dir)
    root.pathError = error
    if (error !== "") return

    var expandedDir = dir.replace(/^~/, Quickshell.env("HOME"))
    var inner = "set -e; git clone " + Util.shellQuote(url) + " " + Util.shellQuote(expandedDir) +
      " && cd " + Util.shellQuote(expandedDir) + " && ./install.sh" +
      "; echo; read -n1 -p 'Press any key to close'"
    runShellInFloatingTerminal(inner)
    root.saveDotfilesRepo(dir)
  }

  function openRepo() {
    if (!configured) return
    Quickshell.execDetached(["xdg-open", repoDir])
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.status = Model.parseStatus(text())
    onLoadFailed: root.status = Model.defaultStatus()
  }

  Process {
    id: syncProc
    command: []
    onExited: {
      root.syncing = false
      settleTimer.restart()
    }
  }

  Timer {
    id: settleTimer
    interval: 2000
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) root.refresh()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    foreground: root.iconColor
    tooltipText: root.tooltipText
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.tooltipText
          color: root.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // First-run guided setup: shown until a repo is configured, so a
        // brand-new user gets through the whole README Quickstart (create
        // repo from template -> clone -> install.sh) by clicking, never by
        // reading the README or typing a shell command themselves.
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: !root.configured

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "GET STARTED"
            color: root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            width: parent.width
            text: "Don't have a repo yet? Create one on GitHub"
            foreground: root.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            bordered: true
            onClicked: root.openTemplatePage()
          }

          TextField {
            id: cloneUrlField
            width: parent.width
            text: root.cloneUrl
            placeholderText: "git@github.com:you/your-dotfiles-repo.git"
            foreground: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            onTextChanged: root.cloneUrl = text
          }

          TextField {
            id: cloneDirField
            width: parent.width
            text: root.cloneTargetDir
            placeholderText: "~/Projects/dotfiles"
            foreground: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            onTextChanged: root.cloneTargetDir = text
          }

          Button {
            width: parent.width
            text: "Clone & set up"
            enabled: root.cloneUrl.trim() !== "" && root.cloneTargetDir.trim() !== ""
            foreground: root.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            bordered: true
            onClicked: root.cloneAndSetup()
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Opens a terminal that clones your repo and runs its setup - " +
                  "watch it in case it asks for a password or git login."
            color: root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            width: parent.width
            text: root.showManualPath ? "Hide manual path entry" : "Already cloned it yourself? Enter the path"
            foreground: root.dim
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            bordered: false
            onClicked: root.showManualPath = !root.showManualPath
          }

          PanelSeparator {
            foreground: root.foreground
            visible: root.showManualPath
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.configured || root.showManualPath

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "DOTFILES REPO PATH"
            color: root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: repoField
              width: parent.width - saveButton.width - parent.spacing
              text: root.rawRepoDir
              placeholderText: "~/Projects/dotfiles"
              foreground: root.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              onAccepted: root.saveDotfilesRepo(repoField.text)
            }

            Button {
              id: saveButton
              text: "Save"
              foreground: root.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              bordered: true
              onClicked: root.saveDotfilesRepo(repoField.text)
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.pathError !== ""
          text: root.pathError
          color: root.urgent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          foreground: root.foreground
          visible: root.configured
        }

        Button {
          width: parent.width
          text: root.syncing ? "Syncing…" : "Sync now"
          enabled: root.configured && !root.syncing
          foreground: root.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.syncNow()
        }

        Button {
          width: parent.width
          text: "Run setup (install.sh)"
          enabled: root.configured
          foreground: root.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.runInFloatingTerminal("install.sh")
        }

        Button {
          width: parent.width
          text: "Check package drift"
          enabled: root.configured
          foreground: root.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.runInFloatingTerminal("check-drift.sh")
        }

        Button {
          width: parent.width
          text: "Check symlinks"
          enabled: root.configured
          foreground: root.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.runInFloatingTerminal("check-links.sh")
        }

        Button {
          width: parent.width
          text: "Find adoptable configs"
          enabled: root.configured
          foreground: root.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.runInFloatingTerminal("check-adoptable.sh")
        }

        Button {
          width: parent.width
          text: "Open repo"
          enabled: root.configured
          foreground: root.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.openRepo()
        }
      }
    }
  }
}
