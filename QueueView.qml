import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The queue: an ordered playlist that playback walks down on its own.
// Reordering is keyboard-first (Shift+Up/Down) with hover arrows as the
// discoverable equivalent.
Column {
  id: view

  required property var panel

  spacing: Style.space(2)

  readonly property real totalSeconds: {
    var total = 0
    for (var i = 0; i < panel.queue.length; i++) {
      var episode = panel.queue[i]
      var duration = episode.duration || 0
      total += Math.max(0, duration - (episode.pos || 0))
    }
    return total
  }

  Item {
    width: parent.width
    height: Style.space(24)
    visible: view.panel.queue.length > 0

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: view.panel.queue.length + " queued"
        + (view.totalSeconds > 0 ? " · " + Model.durationLabel(view.totalSeconds) : "")
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    Rectangle {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: clearRow.implicitWidth + Style.space(16)
      height: clearRow.implicitHeight + Style.space(8)
      radius: Style.cornerRadius
      color: clearArea.containsMouse
        ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"
      border.width: 1
      border.color: view.panel.faint

      Text {
        id: clearRow
        anchors.centerIn: parent
        text: "Clear queue"
        color: view.panel.fg
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: clearArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: view.panel.clearQueue()
      }
    }
  }

  Repeater {
    model: view.panel.queue

    Item {
      id: queueItem
      required property int index
      required property var modelData

      width: parent.width
      height: episodeRow.height

      EpisodeRow {
        id: episodeRow
        panel: view.panel
        episode: queueItem.modelData
        ordinal: queueItem.index + 1
        selected: view.panel.view === "queue" && view.panel.cursor === queueItem.index
        anchors.left: parent.left
        anchors.right: reorder.left
        anchors.rightMargin: Style.space(2)

        onActivated: {
          view.panel.cursor = queueItem.index
          view.panel.playEpisode(queueItem.modelData, {})
        }
        onSecondary: view.panel.removeFromQueue(queueItem.modelData)
      }

      // Reorder + remove. Shown on hover or when the row is the cursor, so
      // a quiet queue stays quiet.
      Row {
        id: reorder
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)
        opacity: hoverGate.containsMouse
          || (view.panel.view === "queue" && view.panel.cursor === queueItem.index) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 90 } }

        PanelActionButton {
          iconText: ""
          tooltipText: "Move up"
          enabled: queueItem.index > 0
          foreground: view.panel.dim
          hoverColor: Color.accent
          fontFamily: view.panel.fontName
          fontSize: Math.max(8, Style.font.caption)
          onClicked: view.panel.moveInQueue(queueItem.modelData, -1)
        }
        PanelActionButton {
          iconText: ""
          tooltipText: "Move down"
          enabled: queueItem.index < view.panel.queue.length - 1
          foreground: view.panel.dim
          hoverColor: Color.accent
          fontFamily: view.panel.fontName
          fontSize: Math.max(8, Style.font.caption)
          onClicked: view.panel.moveInQueue(queueItem.modelData, 1)
        }
        PanelActionButton {
          iconText: ""
          tooltipText: "Remove from queue"
          foreground: view.panel.dim
          hoverColor: Color.urgent
          fontFamily: view.panel.fontName
          fontSize: Math.max(8, Style.font.caption)
          onClicked: view.panel.removeFromQueue(queueItem.modelData)
        }
      }

      MouseArea {
        id: hoverGate
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        propagateComposedEvents: true
      }
    }
  }

  Column {
    visible: view.panel.queue.length === 0
    width: parent.width
    topPadding: Style.space(18)
    bottomPadding: Style.space(14)
    spacing: Style.space(6)

    Text {
      width: parent.width
      text: ""
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.heading
      horizontalAlignment: Text.AlignHCenter
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "the queue is empty"
      color: view.panel.fg
      font.family: view.panel.fontName
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: view.panel.inbox.length > 0
        ? "press Enter on an inbox episode to line it up"
        : "queue something from a show's episode list"
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
