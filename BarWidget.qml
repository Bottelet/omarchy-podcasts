import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "bottelet.podcasts"

  // Mirrored off the panel so the bar chip can badge and animate itself
  // without the panel having to reach back into the bar.
  readonly property int inboxCount: panelLoader.item ? panelLoader.item.inboxCount : 0
  readonly property bool playing: panelLoader.item ? panelLoader.item.playing === true : false
  readonly property real playProgress: panelLoader.item ? panelLoader.item.playProgress : 0

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refreshAll) panelLoader.item.refreshAll()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function togglePlayback() {
    if (panelLoader.item && panelLoader.item.togglePlay) panelLoader.item.togglePlay()
  }

  // Shape contract for shell summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function openSettings() {
    if (panelLoader.item && panelLoader.item.openSettings) panelLoader.item.openSettings()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity (see the weather plugin for the long-form rationale).
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-podcast while idle, nf-fa-play while a queue is running — the
    // chip says what the plugin is doing without needing a tooltip.
    text: root.playing ? "" : ""
    slotSize: Style.bar.statusSlot
    active: root.inboxCount > 0 || root.playing
    useActiveColor: true
    activeColor: Color.accent
    tooltipText: ""

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.togglePlayback()
      else root.togglePanel()
    }
  }

  // Playback progress: a hairline under the chip. Deliberately quiet — the
  // bar is not the place for a scrubber.
  Rectangle {
    visible: root.playing && root.playProgress > 0
    height: Math.max(1, Style.space(2))
    width: parent.width * Math.max(0, Math.min(1, root.playProgress))
    color: Color.accent
    opacity: 0.8
    anchors.bottom: parent.bottom
    anchors.left: parent.left
  }

  // Untriaged inbox count — not total unplayed. Triage is the whole point,
  // so the badge only ever means "episodes waiting on a decision".
  Rectangle {
    visible: root.inboxCount > 0
    width: Math.max(height, badgeText.implicitWidth + Style.space(4))
    height: Style.space(11)
    radius: height / 2
    color: Color.accent
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(1)

    Text {
      id: badgeText
      anchors.centerIn: parent
      text: root.inboxCount > 99 ? "99+" : root.inboxCount
      textFormat: Text.PlainText
      color: Color.background
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.max(8, Style.font.caption - 2)
      font.bold: true
    }
  }
}
