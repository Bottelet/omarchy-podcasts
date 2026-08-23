import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The inbox: everything that has landed since you subscribed and that you
// have not yet made a decision about. Triaging it to zero is the whole
// interaction — so the only affordances here are queue, play and archive.
Column {
  id: view

  required property var panel

  spacing: Style.space(2)

  Item {
    width: parent.width
    height: Style.space(24)
    visible: view.panel.inbox.length > 0

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: view.panel.inbox.length + " waiting"
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    Rectangle {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: archiveRow.implicitWidth + Style.space(16)
      height: archiveRow.implicitHeight + Style.space(8)
      radius: Style.cornerRadius
      color: archiveArea.containsMouse
        ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"
      border.width: 1
      border.color: view.panel.faint

      Row {
        id: archiveRow
        anchors.centerIn: parent
        spacing: Style.space(6)

        Text {
          text: ""
          color: view.panel.dim
          font.family: view.panel.fontName
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          text: "Archive all"
          color: view.panel.fg
          font.family: view.panel.fontName
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      MouseArea {
        id: archiveArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: view.panel.archiveAll()
      }
    }
  }

  Repeater {
    model: view.panel.inbox

    EpisodeRow {
      required property int index
      required property var modelData

      panel: view.panel
      episode: modelData
      selected: view.panel.view === "inbox" && view.panel.cursor === index
      trailingIcon: ""
      trailingTooltip: "Archive"

      onActivated: {
        view.panel.cursor = index
        view.panel.enqueueEpisode(modelData, false)
        view.panel.note("queued · " + modelData.title)
      }
      onSecondary: {
        view.panel.cursor = index
        view.panel.playEpisode(modelData, {})
      }
      onTrailingClicked: view.panel.archiveEpisode(modelData)
    }
  }

  // Inbox zero. Worth a moment of praise — it is the state the whole design
  // is pushing you toward.
  Column {
    visible: view.panel.inbox.length === 0
    width: parent.width
    topPadding: Style.space(18)
    bottomPadding: Style.space(14)
    spacing: Style.space(6)

    Text {
      width: parent.width
      text: view.panel.shows.length === 0 ? "" : ""
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.heading
      horizontalAlignment: Text.AlignHCenter
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: view.panel.shows.length === 0
        ? "no subscriptions yet"
        : "inbox zero — nothing waiting on you"
      color: view.panel.fg
      font.family: view.panel.fontName
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: view.panel.shows.length === 0
        ? "open Shows to search the directory or paste a feed URL"
        : (view.panel.queue.length > 0
          ? view.panel.queue.length + " in the queue, ready when you are"
          : "new episodes will show up here after the next check")
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }
  }
}
