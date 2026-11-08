import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Mouse and trackpad scroll settings.
//
// State lives in Hyprland, not here: `omarchy-scroll get` reads the effective
// values back out of `hyprctl getoption` on every open, so the panel can never
// drift from the compositor. Dragging a slider previews through `omarchy-scroll
// set` (a Lua hl.config() eval, since Omarchy's Lua parser rejects `hyprctl
// keyword`). Nothing is written to disk until the user explicitly opts in with
// "Keep across reloads", which runs `enable` (one marked line appended to
// input.lua). From then on, releasing a slider calls `save`, which rewrites the
// plugin-owned ~/.config/hypr/scroll.lua so the value survives a reload.
//
// Layout, cursor model, and chrome follow the dev-gallery template: j/k walks
// targets, h/l adjusts the focused slider, Enter activates, Esc closes.
Item {
  id: root

  // ---- plugin lifecycle ---------------------------------------------------
  property bool closingFromHost: false
  property var shell: null
  property var manifest: null

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    reload()
    Qt.callLater(function() {
      if (keyCatcher) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  // ---- theme --------------------------------------------------------------
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: Style.font.family

  // PanelSlider takes a whole bar object; the gallery's fake-bar trick keeps
  // it usable outside the bar.
  readonly property var fakeBar: QtObject {
    readonly property color foreground: root.foreground
    readonly property color background: root.background
    readonly property color urgent: root.urgent
    readonly property string fontFamily: root.fontFamily
    readonly property string position: "top"
    readonly property bool vertical: false
    readonly property int barSize: Style.bar.sizeHorizontal
  }

  // ---- settings state -----------------------------------------------------
  property real mouseFactor: 1.0
  property bool mouseNatural: false
  property real padFactor: 0.4
  property bool padNatural: false
  property string scrollMethod: ""
  property int emulateDiscrete: 1
  property bool hasTouchpad: false
  property bool loaded: false
  // True once input.lua requires scroll.lua, i.e. the user has consented to
  // persistence. Until then changes are live-only and nothing touches disk.
  property bool persisted: false

  // The backend ships inside the plugin so a git install is self-contained:
  // `omarchy plugin add` only clones the repo and moves it into place, it never
  // runs an installer. PluginRegistry stamps __sourceDir onto the manifest and
  // the shell host hands the manifest to this panel, which is how the QML finds
  // its own directory without knowing where the user keeps plugins.
  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : "eusener.scroll"
  readonly property string sourceDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""
  readonly property string helper: sourceDir ? sourceDir + "/bin/omarchy-scroll" : ""

  // Non-empty whenever the backend could not be read. Surfaced in the panel,
  // because the failure mode otherwise is a page of plausible-looking defaults
  // whose controls quietly do nothing.
  property string errorText: ""

  // Hyprland's own vocabulary, mapped to something readable. "" is Hyprland's
  // unset state, which means libinput picks per device.
  readonly property var methodOptions: ["Automatic", "Two fingers", "Edge", "On button down", "Disabled"]
  readonly property var methodValues: ["", "2fg", "edge", "on_button_down", "no_scroll"]
  readonly property var discreteOptions: ["Off", "Automatic", "Force"]

  function methodLabel(v) {
    var i = methodValues.indexOf(v)
    return i >= 0 ? methodOptions[i] : methodOptions[0]
  }

  function reload() {
    if (!helper) {
      errorText = "This panel could not locate its own plugin directory, so the backend cannot be run."
      return
    }
    getProc.running = true
  }

  function applyLive(key, value) {
    if (!helper) return
    setProc.command = ["/bin/sh", "-c", "exec \"$0\" set \"$1\" \"$2\"", root.helper, key, String(value)]
    setProc.running = true
  }

  function persist() {
    if (!helper || !persisted) return
    saveProc.running = true
  }

  // Tracks whether this run produced usable JSON, so the exit handler and the
  // stdout handler can settle the error state in either order.
  property bool parsedOk: false

  Process {
    id: getProc
    // Run through sh so the process always spawns and always yields an exit
    // code. Handing QML a command that does not exist produces no exit and no
    // stream at all, which is how a missing backend used to slip past as a
    // page of plausible defaults. $0 carries the path, so no quoting to get
    // wrong. 127 is sh's "not found".
    command: ["/bin/sh", "-c", "exec \"$0\" get", root.helper]
    onRunningChanged: if (running) root.parsedOk = false
    onExited: function(exitCode, exitStatus) {
      if (!root.parsedOk)
        root.errorText = "Could not run the backend (exit " + exitCode + "). Check that "
          + root.helper + " exists and is executable."
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.mouseFactor = Number(d.mouseFactor)
          root.mouseNatural = !!d.mouseNatural
          root.padFactor = Number(d.padFactor)
          root.padNatural = !!d.padNatural
          root.scrollMethod = String(d.scrollMethod || "")
          root.emulateDiscrete = Number(d.emulateDiscrete)
          root.hasTouchpad = !!d.hasTouchpad
          root.persisted = !!d.persisted
          root.loaded = true
          root.parsedOk = true
          root.errorText = ""
          root.clampCursor()
        } catch (e) {
          // No output at all lands here too, which is what a missing or
          // non-executable bin/omarchy-scroll looks like from QML.
          root.errorText = "Could not read the current settings. Check that "
            + root.helper + " exists and is executable."
        }
      }
    }
  }

  Process {
    id: setProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.errorText = "Failed to apply the change (exit " + exitCode + ")."
    }
  }

  Process {
    id: saveProc
    command: ["/bin/sh", "-c", "exec \"$0\" save", root.helper]
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.errorText = "Failed to save to scroll.lua (exit " + exitCode + ")."
    }
  }

  // Explicit consent: only ever started from the "Keep across reloads" button.
  // `enable` writes scroll.lua from the current live values and appends the
  // require line to input.lua.
  Process {
    id: enableProc
    command: ["/bin/sh", "-c", "exec \"$0\" enable", root.helper]
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.errorText = "Could not enable persistence (exit " + exitCode + ")."
      root.reload()
    }
  }

  function enablePersistence() {
    if (!helper) return
    enableProc.running = true
  }

  Process {
    id: resetProc
    command: ["/bin/sh", "-c", "exec \"$0\" reset", root.helper]
    // reset writes the file and reloads Hyprland; re-read once it settles so
    // the controls snap back to the restored defaults.
    onExited: reloadTimer.restart()
  }

  Timer {
    id: reloadTimer
    interval: 400
    onTriggered: root.reload()
  }

  // ---- cursor model -------------------------------------------------------
  //
  // Same shape as the gallery/wifi/audio panels: one flat target list, so j/k
  // crosses section boundaries without special-casing.
  property string focusSection: "persist"

  readonly property var visibleSections: {
    var s = persisted ? [] : ["persist"]
    s = s.concat(["mouse-speed", "mouse-natural"])
    if (hasTouchpad) s = s.concat(["pad-speed", "pad-natural"])
    return s.concat(["method", "discrete", "reset"])
  }

  readonly property bool cursorAdjustsValue:
    focusSection === "mouse-speed" || focusSection === "pad-speed"

  function moveCursor(dy) {
    var list = visibleSections
    var i = list.indexOf(focusSection)
    if (i < 0) i = 0
    var next = Math.max(0, Math.min(list.length - 1, i + (dy > 0 ? 1 : -1)))
    focusSection = list[next]
  }

  // h/l nudges the focused slider; elsewhere it is a no-op rather than a
  // surprise jump to another control.
  function moveCursorH(dx) {
    if (!cursorAdjustsValue) return
    var stepped = dx > 0 ? 0.05 : -0.05
    if (focusSection === "mouse-speed") {
      mouseFactor = Math.max(0.1, Math.min(3.0, mouseFactor + stepped))
      applyLive("mouse-factor", mouseFactor.toFixed(2))
      persistDebounce.restart()
    } else if (focusSection === "pad-speed") {
      padFactor = Math.max(0.1, Math.min(3.0, padFactor + stepped))
      applyLive("pad-factor", padFactor.toFixed(2))
      persistDebounce.restart()
    }
  }

  function activateCursor() {
    switch (focusSection) {
      case "mouse-natural": toggleMouseNatural(); break
      case "pad-natural": togglePadNatural(); break
      case "method": methodDropdown.toggle(); break
      case "discrete": discreteDropdown.toggle(); break
      case "persist": enablePersistence(); break
      case "reset": resetProc.running = true; break
    }
  }

  function clampCursor() {
    if (visibleSections.indexOf(focusSection) < 0)
      focusSection = visibleSections[0]
  }

  // Keyboard nudges fire fast; collapse them into one file write.
  Timer {
    id: persistDebounce
    interval: 250
    onTriggered: root.persist()
  }

  function toggleMouseNatural() {
    mouseNatural = !mouseNatural
    applyLive("mouse-natural", mouseNatural)
    persist()
  }

  function togglePadNatural() {
    padNatural = !padNatural
    applyLive("pad-natural", padNatural)
    persist()
  }

  // ---- window -------------------------------------------------------------
  FloatingWindow {
    id: window
    title: "Scroll settings"
    color: root.background
    implicitWidth: 560
    implicitHeight: 700
    minimumSize: Qt.size(460, 460)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: methodDropdown.popupOpen || discreteDropdown.popupOpen
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) root.moveCursor(dy)
          else if (dx !== 0) root.moveCursorH(dx)
        }
        onActivateRequested: root.activateCursor()
        onCloseRequested: root.requestClose()

        ScrollView {
          id: scrollArea
          anchors.fill: parent
          anchors.margins: Style.space(18)
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          Column {
            width: scrollArea.availableWidth
            spacing: Style.space(20)

            // ---- header ------------------------------------------------
            Column {
              width: parent.width
              spacing: Style.space(4)

              Text {
                text: "Scroll"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                font.bold: true
              }
              Text {
                text: "Speed and direction for the mouse wheel and the trackpad. Changes apply as you drag." + (root.persisted ? " They are saved to ~/.config/hypr/scroll.lua." : "") + " j/k to walk · h/l to adjust · Enter to activate · Esc to close."
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: parent.width
                wrapMode: Text.WordWrap
              }
            }

            // ---- backend failure ---------------------------------------
            BorderSurface {
              width: parent.width
              visible: root.errorText.length > 0
              implicitHeight: errorCol.implicitHeight + Style.spacing.rowPaddingX * 2
              color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
              radius: Style.cornerRadius
              borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.45), 1)

              Column {
                id: errorCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(14)
                spacing: Style.space(4)

                Text {
                  text: "Backend unavailable"
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
                  text: root.errorText
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }
            }

            // ---- persistence consent -----------------------------------
            BorderSurface {
              width: parent.width
              visible: root.loaded && !root.persisted
              implicitHeight: consentCol.implicitHeight + Style.spacing.rowPaddingX * 2
              color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08)
              radius: Style.cornerRadius
              borderSpec: Border.flat(Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.40), 1)

              Column {
                id: consentCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(14)
                spacing: Style.space(8)

                Text {
                  text: "Changes are live only"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
                  text: "They are lost on the next Hyprland reload. To keep them, this panel will write ~/.config/hypr/scroll.lua and append one line, require(\"hypr.scroll\"), to your ~/.config/hypr/input.lua. Nothing is written until you choose to. Undo any time with: omarchy-scroll disable"
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
                Button {
                  text: "Keep across reloads"
                  iconText: "󰆓"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  hasCursor: root.focusSection === "persist"
                  onHovered: function(h) { if (h) root.focusSection = "persist" }
                  onClicked: {
                    root.focusSection = "persist"
                    root.enablePersistence()
                  }
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            // ---- mouse -------------------------------------------------
            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "Mouse"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              CursorSurface {
                width: parent.width
                implicitHeight: mouseRow.implicitHeight + Style.spacing.rowPaddingX * 2
                outline: true
                foreground: root.foreground
                accent: root.accent
                hasCursor: root.focusSection === "mouse-speed"

                HoverHandler {
                  onHoveredChanged: if (hovered) root.focusSection = "mouse-speed"
                }

                Row {
                  id: mouseRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(10)

                  Text {
                    text: "󰍽"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    width: 22
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  PanelSlider {
                    id: mouseSlider
                    bar: root.fakeBar
                    width: parent.width - 92
                    anchors.verticalCenter: parent.verticalCenter
                    minimum: 0.1
                    maximum: 3.0
                    step: 0.05
                    value: root.mouseFactor
                    onMoved: function(v) {
                      root.mouseFactor = v
                      root.applyLive("mouse-factor", v.toFixed(2))
                    }
                    onReleased: function(v) {
                      root.mouseFactor = v
                      root.applyLive("mouse-factor", v.toFixed(2))
                      root.persist()
                    }
                  }

                  Text {
                    text: (mouseSlider.dragging ? mouseSlider.liveValue : root.mouseFactor).toFixed(2) + "x"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    width: 44
                    horizontalAlignment: Text.AlignRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              Toggle {
                width: parent.width
                label: "Natural scrolling"
                description: "Content follows the wheel instead of the viewport."
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                checked: root.mouseNatural
                hasCursor: root.focusSection === "mouse-natural"
                onHovered: function(h) { if (h) root.focusSection = "mouse-natural" }
                onClicked: {
                  root.focusSection = "mouse-natural"
                  root.toggleMouseNatural()
                }
              }
            }

            // ---- trackpad ----------------------------------------------
            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.hasTouchpad

              PanelSectionHeader {
                text: "Trackpad"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              CursorSurface {
                width: parent.width
                implicitHeight: padRow.implicitHeight + Style.spacing.rowPaddingX * 2
                outline: true
                foreground: root.foreground
                accent: root.accent
                hasCursor: root.focusSection === "pad-speed"

                HoverHandler {
                  onHoveredChanged: if (hovered) root.focusSection = "pad-speed"
                }

                Row {
                  id: padRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(10)

                  Text {
                    text: "󰟸"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    width: 22
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  PanelSlider {
                    id: padSlider
                    bar: root.fakeBar
                    width: parent.width - 92
                    anchors.verticalCenter: parent.verticalCenter
                    minimum: 0.1
                    maximum: 3.0
                    step: 0.05
                    value: root.padFactor
                    onMoved: function(v) {
                      root.padFactor = v
                      root.applyLive("pad-factor", v.toFixed(2))
                    }
                    onReleased: function(v) {
                      root.padFactor = v
                      root.applyLive("pad-factor", v.toFixed(2))
                      root.persist()
                    }
                  }

                  Text {
                    text: (padSlider.dragging ? padSlider.liveValue : root.padFactor).toFixed(2) + "x"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    width: 44
                    horizontalAlignment: Text.AlignRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              Toggle {
                width: parent.width
                label: "Natural scrolling"
                description: "Two fingers push the content, the way a phone does."
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                checked: root.padNatural
                hasCursor: root.focusSection === "pad-natural"
                onHovered: function(h) { if (h) root.focusSection = "pad-natural" }
                onClicked: {
                  root.focusSection = "pad-natural"
                  root.togglePadNatural()
                }
              }
            }

            // ---- advanced ----------------------------------------------
            Column {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "Advanced"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Dropdown {
                id: methodDropdown
                width: Style.spacing.dropdownWidth
                label: "Scroll method"
                fontFamily: root.fontFamily
                options: root.methodOptions
                value: root.methodLabel(root.scrollMethod)
                hasCursor: root.focusSection === "method"
                onHovered: function(h) { if (h) root.focusSection = "method" }
                onChanged: function(v) {
                  var i = root.methodOptions.indexOf(v)
                  if (i < 0) return
                  root.scrollMethod = root.methodValues[i]
                  root.applyLive("scroll-method", root.scrollMethod)
                  root.persist()
                }
              }

              Dropdown {
                id: discreteDropdown
                width: Style.spacing.dropdownWidth
                label: "Discrete scroll"
                fontFamily: root.fontFamily
                options: root.discreteOptions
                value: root.discreteOptions[Math.max(0, Math.min(2, root.emulateDiscrete))]
                hasCursor: root.focusSection === "discrete"
                onHovered: function(h) { if (h) root.focusSection = "discrete" }
                onChanged: function(v) {
                  var i = root.discreteOptions.indexOf(v)
                  if (i < 0) return
                  root.emulateDiscrete = i
                  root.applyLive("emulate-discrete", i)
                  root.persist()
                }
              }

              Text {
                text: "Discrete scroll turns smooth wheel input into clicks. Automatic only does it for devices that need it; Force applies it everywhere."
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                wrapMode: Text.WordWrap
              }
            }

            PanelSeparator { foreground: root.foreground }

            // ---- reset -------------------------------------------------
            Row {
              width: parent.width
              spacing: Style.space(10)

              Button {
                text: "Reset to defaults"
                iconText: "󰑙"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                hasCursor: root.focusSection === "reset"
                onHovered: function(h) { if (h) root.focusSection = "reset" }
                onClicked: {
                  root.focusSection = "reset"
                  resetProc.running = true
                }
              }

              Text {
                text: "Clears scroll.lua and falls back to Omarchy's defaults."
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }
      }
    }
  }
}
