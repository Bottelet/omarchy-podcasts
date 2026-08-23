import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Now playing: artwork, scrubber, transport, speed, Voice Boost, and the
// chapter list when the feed carries podcast:chapters.
Column {
  id: view

  required property var panel

  spacing: Style.space(10)

  readonly property var episode: panel.currentEpisode
  readonly property var show: panel.currentShow()

  // ---- Nothing loaded yet.
  Column {
    visible: !view.episode
    width: parent.width
    topPadding: Style.space(20)
    bottomPadding: Style.space(16)
    spacing: Style.space(6)

    Text {
      width: parent.width
      text: ""
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.heading
      horizontalAlignment: Text.AlignHCenter
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "nothing playing"
      color: view.panel.fg
      font.family: view.panel.fontName
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: view.panel.queue.length > 0
        ? "press Space to start the queue"
        : "queue an episode first"
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
    }
  }

  // ---- Header: artwork + titles.
  Item {
    visible: !!view.episode
    width: parent.width
    height: Math.max(bigArt.height, titles.implicitHeight)

    Rectangle {
      id: bigArt
      width: Style.space(72)
      height: width
      radius: Math.min(6, Style.cornerRadius)
      color: view.panel.faint
      clip: true
      anchors.left: parent.left
      anchors.top: parent.top

      Image {
        anchors.fill: parent
        source: view.episode && view.episode.showArt ? "file://" + view.episode.showArt : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize.width: 192
        sourceSize.height: 192
        visible: status === Image.Ready
      }

      Text {
        anchors.centerIn: parent
        visible: !(view.episode && view.episode.showArt)
        text: ""
        color: view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.heading
      }
    }

    Column {
      id: titles
      anchors.left: bigArt.right
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(2)
      spacing: Style.space(3)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: view.episode ? (view.episode.show || "") : ""
        color: view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: view.episode ? view.episode.title : ""
        color: view.panel.fg
        font.family: view.panel.fontName
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: view.panel.chapterIndex >= 0 && view.panel.chapters.length > 0
          ? "▸ " + view.panel.chapters[view.panel.chapterIndex].title
          : (view.episode ? Model.ageLabel(view.episode.pub) : "")
        color: view.panel.chapterIndex >= 0 ? Color.accent : view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // ---- Scrubber.
  Column {
    visible: !!view.episode
    width: parent.width
    spacing: Style.space(2)

    PanelSlider {
      id: scrubber
      width: parent.width
      bar: view.panel.bar
      minimum: 0
      maximum: Math.max(1, view.panel.duration)
      step: 15
      value: view.panel.timePos
      onMoved: function(value) { view.panel.timePos = value }
      onReleased: function(value) { view.panel.seekTo(value) }
    }

    Item {
      width: parent.width
      height: elapsed.implicitHeight

      Text {
        id: elapsed
        textFormat: Text.PlainText
        anchors.left: parent.left
        text: Model.clockLabel(view.panel.timePos)
        color: view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
      }
      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        visible: view.panel.duration > 0 && view.panel.playSpeed > 0
        // At 1.6× a 50-minute episode is over in 31 — the number people
        // actually want while deciding whether to start it.
        text: {
          var left = Math.max(0, view.panel.duration - view.panel.timePos)
          return Model.durationLabel(left / Math.max(0.1, view.panel.playSpeed)) + " to go"
        }
        color: view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
      }
      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        text: view.panel.duration > 0 ? Model.clockLabel(view.panel.duration) : "--:--"
        color: view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ---- Transport.
  Item {
    visible: !!view.episode
    width: parent.width
    height: transport.implicitHeight

    Row {
      id: transport
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(10)

      PanelActionButton {
        iconText: ""
        tooltipText: "Back 15 seconds"
        foreground: view.panel.fg
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
        onClicked: view.panel.seekBy(-15)
      }

      Rectangle {
        width: Style.space(38)
        height: Style.space(38)
        radius: width / 2
        color: playArea.containsMouse
          ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"
        border.width: 1
        border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.6)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          anchors.centerIn: parent
          text: view.panel.playing ? "" : ""
          color: Color.accent
          font.family: view.panel.fontName
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: playArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.panel.togglePlay()
        }
      }

      PanelActionButton {
        iconText: ""
        tooltipText: "Forward 30 seconds"
        foreground: view.panel.fg
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
        onClicked: view.panel.seekBy(30)
      }

      PanelActionButton {
        iconText: ""
        tooltipText: "Mark played and go to the next queued episode"
        foreground: view.panel.dim
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
        onClicked: view.panel.finishEpisode()
      }
    }
  }

  // ---- Speed + Voice Boost.
  Item {
    visible: !!view.episode
    width: parent.width
    height: speedRow.implicitHeight

    Row {
      id: speedRow
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      PanelActionButton {
        iconText: "−"
        tooltipText: "Slower"
        foreground: view.panel.dim
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
        onClicked: view.panel.stepSpeed(-0.1)
      }
      Text {
        textFormat: Text.PlainText
        width: Style.space(34)
        text: Model.speedLabel(view.panel.playSpeed)
        color: view.panel.playSpeed !== 1 ? Color.accent : view.panel.fg
        font.family: view.panel.fontName
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }
      PanelActionButton {
        iconText: "+"
        tooltipText: "Faster"
        foreground: view.panel.dim
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
        onClicked: view.panel.stepSpeed(0.1)
      }
      Text {
        textFormat: Text.PlainText
        visible: !!view.show
        text: "for this show"
        color: view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "Voice Boost"
        color: view.panel.voiceBoost ? Color.accent : view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      ToggleSwitch {
        checked: view.panel.voiceBoost
        foreground: view.panel.fg
        accent: Color.accent
        anchors.verticalCenter: parent.verticalCenter
        onToggled: view.panel.setVoiceBoost(!view.panel.voiceBoost)
      }
    }
  }

  // ---- Chapters, when the feed has them.
  Column {
    visible: !!view.episode && view.panel.chapters.length > 0
    width: parent.width
    spacing: Style.space(1)

    PanelSectionHeader {
      text: "CHAPTERS"
      foreground: view.panel.fg
      fontFamily: view.panel.fontName
    }

    Repeater {
      model: view.panel.chapters

      Item {
        id: chapterRow
        required property int index
        required property var modelData

        readonly property bool current: view.panel.chapterIndex === index

        width: parent.width
        height: Style.space(24)

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: chapterRow.current || chapterArea.containsMouse
            ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"
        }

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(46)
          text: Model.clockLabel(chapterRow.modelData.start)
          color: view.panel.dim
          font.family: view.panel.fontName
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: Style.space(58)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: chapterRow.modelData.title
          color: chapterRow.current ? Color.accent : view.panel.fg
          font.family: view.panel.fontName
          font.pixelSize: Style.font.caption
          font.bold: chapterRow.current
          elide: Text.ElideRight
        }

        MouseArea {
          id: chapterArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.panel.seekTo(chapterRow.modelData.start)
        }
      }
    }
  }

  // ---- Episode notes.
  Text {
    textFormat: Text.PlainText
    visible: !!view.episode && text !== ""
    width: parent.width
    text: view.episode ? (view.episode.desc || "") : ""
    color: view.panel.dim
    font.family: view.panel.fontName
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    maximumLineCount: 6
    elide: Text.ElideRight
  }
}
