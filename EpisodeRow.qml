import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One episode line, shared by the Inbox, Queue and per-show lists.
//
// Every string here comes from a remote feed, so every Text is PlainText —
// no RichText path exists for feed content anywhere in this plugin.
Item {
  id: row

  required property var panel
  required property var episode
  property bool selected: false
  property bool showArtwork: true
  property bool showName: true
  property string trailingIcon: ""
  property string trailingTooltip: ""
  property int ordinal: 0

  signal activated()
  signal secondary()
  signal trailingClicked()

  readonly property color fg: panel.fg
  readonly property color dim: panel.dim
  readonly property bool isCurrent: panel.currentId === episode.id
  readonly property real progress: Model.progressOf(episode)

  width: parent ? parent.width : 0
  height: content.implicitHeight + Style.space(12)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: row.selected || rowArea.containsMouse
      ? Style.hoverFillFor(row.fg, Color.accent) : "transparent"
    border.width: row.selected ? 1 : 0
    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5)
  }

  // Ordinal for the queue — position is the point of that view.
  Text {
    id: ordinalText
    visible: row.ordinal > 0
    width: visible ? Style.space(16) : 0
    text: row.ordinal
    textFormat: Text.PlainText
    color: row.dim
    font.family: panel.fontName
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignRight
    anchors.left: parent.left
    anchors.leftMargin: Style.space(4)
    anchors.top: parent.top
    anchors.topMargin: Style.space(10)
  }

  Rectangle {
    id: art
    visible: row.showArtwork
    width: visible ? Style.space(34) : 0
    height: width
    radius: Math.min(4, Style.cornerRadius)
    color: row.panel.faint
    clip: true
    anchors.left: ordinalText.visible ? ordinalText.right : parent.left
    anchors.leftMargin: Style.space(6)
    anchors.top: parent.top
    anchors.topMargin: Style.space(6)

    Image {
      anchors.fill: parent
      source: row.episode.showArt ? "file://" + row.episode.showArt : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      sourceSize.width: 96
      sourceSize.height: 96
      visible: status === Image.Ready
    }

    Text {
      anchors.centerIn: parent
      visible: !row.episode.showArt
      text: ""
      color: row.dim
      font.family: panel.fontName
      font.pixelSize: Style.font.bodySmall
    }
  }

  Column {
    id: content
    anchors.left: art.visible ? art.right : (ordinalText.visible ? ordinalText.right : parent.left)
    anchors.leftMargin: Style.space(8)
    anchors.right: trailing.left
    anchors.rightMargin: Style.space(8)
    anchors.top: parent.top
    anchors.topMargin: Style.space(6)
    spacing: Style.space(2)

    Row {
      spacing: Style.space(6)
      visible: row.showName

      Text {
        visible: row.isCurrent
        text: panel.playing ? "" : ""
        color: Color.accent
        font.family: panel.fontName
        font.pixelSize: Math.max(8, Style.font.caption - 1)
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: row.episode.show || ""
        color: row.dim
        font.family: panel.fontName
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: row.episode.title || "(untitled)"
      color: row.fg
      font.family: panel.fontName
      font.pixelSize: Style.font.bodySmall
      font.bold: row.isCurrent
      elide: Text.ElideRight
      maximumLineCount: 2
      wrapMode: Text.WordWrap
    }

    Row {
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.remainingLabel(row.episode) || Model.durationLabel(row.episode.duration)
        color: row.dim
        font.family: panel.fontName
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        text: Model.ageLabel(row.episode.pub)
        color: row.dim
        font.family: panel.fontName
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        visible: row.episode.state === "archived"
        text: "archived"
        color: row.dim
        font.family: panel.fontName
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        visible: row.episode.state === "played"
        text: "played"
        color: row.dim
        font.family: panel.fontName
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // Resume marker: only worth drawing once there is progress to show.
    Rectangle {
      visible: row.progress > 0.005 && row.progress < 0.995
      width: parent.width
      height: Math.max(2, Style.space(2))
      radius: height / 2
      color: row.panel.faint

      Rectangle {
        width: parent.width * row.progress
        height: parent.height
        radius: parent.radius
        color: Color.accent
      }
    }
  }

  PanelActionButton {
    id: trailing
    visible: row.trailingIcon !== ""
    iconText: row.trailingIcon
    tooltipText: row.trailingTooltip
    foreground: row.dim
    hoverColor: Color.accent
    fontFamily: panel.fontName
    fontSize: Style.font.bodySmall
    anchors.right: parent.right
    anchors.rightMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
    onClicked: row.trailingClicked()
  }

  MouseArea {
    id: rowArea
    anchors.fill: parent
    anchors.rightMargin: trailing.visible ? trailing.width + Style.space(8) : 0
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) row.secondary()
      else row.activated()
    }
  }
}
