import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// App Sweep: a floating checkbox list for bulk-removing packages and web
// apps. Panel-kind plugin with no bar presence; summon it with
//   omarchy-shell shell toggle io.github.antoniowav.appsweep '{}'
// (optionally pass {"tab":"webapps"} to open on the web apps tab).
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string tab: "packages" // "packages" | "webapps"
  property string phase: "list"   // "list" | "confirm" | "working"
  property string filterText: ""
  property string statusText: ""

  property var packages: []
  property var webapps: []
  property bool packagesLoaded: false
  property bool webappsLoaded: false

  // Checked names live in plain maps; checkedRev is bumped on every change so
  // bindings that read the maps re-evaluate without rebuilding delegates.
  property var checkedPkgs: ({})
  property var checkedApps: ({})
  property int checkedRev: 0
  property int lastRemoveCount: 0

  readonly property var currentItems: tab === "packages" ? packages : webapps
  readonly property var filteredItems: Model.filterItems(currentItems, filterText)
  readonly property int checkedCount: {
    checkedRev
    var map = tab === "packages" ? checkedPkgs : checkedApps
    var n = 0
    for (var k in map) if (map[k] === true) n++
    return n
  }

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(460), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(520), panel.height - Style.gapsOut * 2)

  // ------------------------------------------------------------- list sources

  // Static pipelines only; head -c caps what StdioCollector will ever buffer.
  readonly property string pkgListScript:
    "{ if command -v expac >/dev/null 2>&1; " +
    "then pacman -Qqe | xargs -r expac -Q $'%n\\t%v\\t%m'; " +
    "else pacman -Qe | awk -v OFS='\\t' '{print $1, $2, \"\"}'; fi; } | head -c 524288"

  // Mirrors omarchy-webapp-remove's scan: any launcher whose Exec runs
  // omarchy-launch-webapp or omarchy-webapp-handler is a web app.
  readonly property string webappListScript:
    "find \"$HOME/.local/share/applications\" -name '*.desktop' -print0 2>/dev/null | " +
    "while IFS= read -r -d '' f; do " +
    "grep -q '^Exec=.*\\(omarchy-launch-webapp\\|omarchy-webapp-handler\\)' \"$f\" && " +
    "{ b=\"$(basename \"$f\")\"; printf '%s\\n' \"${b%.desktop}\"; }; " +
    "done | sort -f | head -c 65536"

  // Names arrive as argv, never spliced into the script.
  readonly property string webappRemoveScript:
    "for name in \"$@\"; do OMARCHY_REMOVE_NOTIFY=false omarchy-webapp-remove \"$name\" >/dev/null 2>&1; done"

  // ------------------------------------------------------------------ control

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.tab === "webapps" || payload.tab === "packages") root.tab = payload.tab

    root.opened = true
    root.phase = "list"
    root.filterText = ""
    root.statusText = ""
    root.checkedPkgs = ({})
    root.checkedApps = ({})
    root.checkedRev++
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.antoniowav.appsweep")
  }

  function refresh() {
    if (!pkgListProc.running) {
      root.packagesLoaded = false
      pkgListProc.running = true
    }
    if (!webappListProc.running) {
      root.webappsLoaded = false
      webappListProc.running = true
    }
  }

  function setTab(nextTab) {
    if (root.tab === nextTab) return
    root.tab = nextTab
    root.filterText = ""
    root.statusText = ""
  }

  function currentMap() {
    return root.tab === "packages" ? root.checkedPkgs : root.checkedApps
  }

  function isChecked(name) {
    return currentMap()[name] === true
  }

  function toggleChecked(name) {
    var map = currentMap()
    if (map[name] === true) delete map[name]
    else map[name] = true
    root.checkedRev++
  }

  // Only acts on a filtered list: with no filter this would select every
  // explicitly installed package, one habitual confirm away from removing
  // OS-critical packages.
  function checkAllVisible() {
    if (!root.filterText) return
    var map = currentMap()
    for (var i = 0; i < root.filteredItems.length; i++) map[root.filteredItems[i].name] = true
    root.checkedRev++
  }

  function clearChecked() {
    if (root.tab === "packages") root.checkedPkgs = ({})
    else root.checkedApps = ({})
    root.checkedRev++
  }

  function checkedNames() {
    var map = currentMap()
    var out = []
    for (var k in map) if (map[k] === true) out.push(k)
    out.sort()
    return out
  }

  function requestRemove() {
    if (root.checkedCount === 0 || root.phase !== "list") return
    root.phase = "confirm"
  }

  function executeRemove() {
    var names = checkedNames()
    if (names.length === 0) { root.phase = "list"; return }
    root.lastRemoveCount = names.length
    root.statusText = ""
    root.phase = "working"
    if (root.tab === "packages") {
      pkgRemoveProc.command = ["pkexec", "pacman", "-Rns", "--noconfirm"].concat(names)
      pkgRemoveProc.running = true
    } else {
      webappRemoveProc.command = ["bash", "-c", root.webappRemoveScript, "appsweep"].concat(names)
      webappRemoveProc.running = true
    }
  }

  function pluralize(n, word) {
    return n + " " + word + (n === 1 ? "" : "s")
  }

  // ---------------------------------------------------------------- processes

  Process {
    id: pkgListProc
    command: ["bash", "-c", root.pkgListScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.packages = Model.parsePackages(text)
        root.packagesLoaded = true
      }
    }
  }

  Process {
    id: webappListProc
    command: ["bash", "-c", root.webappListScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.webapps = Model.parseWebapps(text)
        root.webappsLoaded = true
      }
    }
  }

  Process {
    id: pkgRemoveProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: pkgRemoveErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.phase = "list"
      if (exitCode === 0) {
        root.statusText = "Removed " + root.pluralize(root.lastRemoveCount, "package")
        root.checkedPkgs = ({})
        root.checkedRev++
      } else if (exitCode === 126) {
        root.statusText = "Authentication cancelled"
      } else {
        var lines = (pkgRemoveErr.text || "").trim().split("\n")
        var last = lines.length ? lines[lines.length - 1].slice(0, 200) : ""
        root.statusText = last || ("pacman failed (exit " + exitCode + ")")
      }
      pkgListProc.running = true
    }
  }

  Process {
    id: webappRemoveProc
    onExited: function(exitCode) {
      root.phase = "list"
      root.statusText = exitCode === 0
        ? "Removed " + root.pluralize(root.lastRemoveCount, "web app")
        : "Some web apps could not be removed"
      root.checkedApps = ({})
      root.checkedRev++
      webappListProc.running = true
    }
  }

  // ----------------------------------------------------------------- the card

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "appsweep"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: if (root.phase === "list") root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.phase === "working") { event.accepted = true; return }
          if (event.key === Qt.Key_Escape) {
            if (root.phase === "confirm") root.phase = "list"
            else if (root.filterText) root.filterText = ""
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.phase === "confirm") root.executeRemove()
            else root.requestRemove()
            event.accepted = true
          } else if (root.phase === "list" && Util.editsFilter(event, root.filterText)) {
            root.filterText = Util.editedFilter(event, root.filterText)
            event.accepted = true
          } else if (root.phase === "list" && event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.filterText += event.text
            event.accepted = true
          }
        }
      }

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // Header: title + close.
        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(30)

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "App Sweep"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.weight: Font.DemiBold
          }

          Button {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "✕"
            fontFamily: root.fontFamily
            foreground: root.foreground
            onClicked: root.dismiss()
          }
        }

        // Tabs + select helpers.
        Row {
          id: tabRow
          anchors.top: header.bottom
          anchors.topMargin: Style.space(8)
          anchors.left: parent.left
          spacing: Style.space(6)

          Button {
            text: "Packages (" + root.packages.length + ")"
            fontFamily: root.fontFamily
            foreground: root.foreground
            selected: root.tab === "packages"
            onClicked: root.setTab("packages")
          }
          Button {
            text: "Web Apps (" + root.webapps.length + ")"
            fontFamily: root.fontFamily
            foreground: root.foreground
            selected: root.tab === "webapps"
            onClicked: root.setTab("webapps")
          }
        }

        Row {
          anchors.top: header.bottom
          anchors.topMargin: Style.space(8)
          anchors.right: parent.right
          spacing: Style.space(6)

          Button {
            text: "All"
            fontFamily: root.fontFamily
            foreground: root.foreground
            opacity: root.filterText.length > 0 ? 1 : 0.35
            tooltipText: "Selects the filtered rows — type a filter first"
            onClicked: root.checkAllVisible()
          }
          Button {
            text: "None"
            fontFamily: root.fontFamily
            foreground: root.foreground
            onClicked: root.clearChecked()
          }
        }

        // Type-to-filter readout.
        Rectangle {
          id: filterLine
          anchors.top: tabRow.bottom
          anchors.topMargin: Style.space(8)
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(28)
          radius: Style.space(6)
          color: Util.alpha(root.foreground, 0.06)

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Type to filter…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }

        // The checkbox list.
        ListView {
          id: listView
          anchors.top: filterLine.bottom
          anchors.topMargin: Style.space(8)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: footer.top
          anchors.bottomMargin: Style.space(8)
          clip: true
          model: root.filteredItems
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds

          Text {
            visible: listView.count === 0
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: {
              var loaded = root.tab === "packages" ? root.packagesLoaded : root.webappsLoaded
              if (!loaded) return "Loading…"
              return root.filterText ? "No matches" : "Nothing to remove"
            }
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          delegate: Rectangle {
            id: row
            required property var modelData
            readonly property bool checked: {
              root.checkedRev
              return root.isChecked(modelData.name)
            }
            width: listView.width
            height: Style.space(28)
            radius: Style.space(6)
            color: rowArea.containsMouse ? Util.alpha(root.foreground, 0.08) : "transparent"

            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.toggleChecked(row.modelData.name)
            }

            Rectangle {
              id: checkbox
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(15)
              height: Style.space(15)
              radius: Style.space(4)
              color: row.checked ? Color.accent : "transparent"
              border.width: Math.max(1, Style.space(1))
              border.color: row.checked ? Color.accent : Util.alpha(root.foreground, 0.4)

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                visible: row.checked
                text: "✓"
                color: root.background
                font.pixelSize: Style.space(11)
                font.weight: Font.Bold
              }
            }

            Text {
              id: sizeText
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.formatSize(row.modelData.bytes)
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.small
            }

            Text {
              id: versionText
              textFormat: Text.PlainText
              anchors.right: sizeText.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, Style.space(110))
              text: row.modelData.version
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.small
              elide: Text.ElideLeft
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: checkbox.right
              anchors.leftMargin: Style.space(8)
              anchors.right: versionText.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: row.modelData.name
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }
        }

        // Footer: status + remove.
        Item {
          id: footer
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(32)

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: removeButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText || (root.checkedCount > 0 ? root.checkedCount + " selected" : "")
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.small
            elide: Text.ElideRight
          }

          Button {
            id: removeButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Remove (" + root.checkedCount + ")"
            fontFamily: root.fontFamily
            foreground: root.checkedCount > 0 ? Color.accent : root.foreground
            bordered: true
            opacity: root.checkedCount > 0 ? 1 : 0.4
            onClicked: root.requestRemove()
          }
        }
      }

      // Confirm / working overlay.
      Rectangle {
        anchors.fill: parent
        radius: root.cornerRadius
        visible: root.phase !== "list"
        color: Util.alpha(root.background, 0.92)

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          anchors.centerIn: parent
          width: parent.width - root.contentMargin * 4
          spacing: Style.space(14)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: {
              if (root.phase === "working") return "Removing…"
              if (root.tab === "packages")
                return "Remove " + root.pluralize(root.checkedCount, "package") + " with pacman -Rns?\n" +
                       "Unused dependencies and their config files are removed too."
              return "Remove " + root.pluralize(root.checkedCount, "web app launcher") + "?"
            }
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Row {
            visible: root.phase === "confirm"
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(10)

            Button {
              text: "Cancel"
              fontFamily: root.fontFamily
              foreground: root.foreground
              bordered: true
              onClicked: root.phase = "list"
            }
            Button {
              text: "Remove"
              fontFamily: root.fontFamily
              foreground: Color.accent
              bordered: true
              onClicked: root.executeRemove()
            }
          }
        }
      }
    }
  }
}
