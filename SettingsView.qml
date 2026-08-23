import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The ⚙ page. Deliberately short: everything here is a global default, and
// anything per-show lives on the show itself in the Shows view.
Column {
  id: view

  required property var panel

  spacing: Style.space(8)

  PanelSectionHeader {
    text: "PLAYBACK"
    foreground: view.panel.fg
    fontFamily: view.panel.fontName
  }

  Item {
    width: parent.width
    height: Style.space(30)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "Default speed"
      color: view.panel.fg
      font.family: view.panel.fontName
      font.pixelSize: Style.font.body
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      PanelActionButton {
        iconText: "−"
        foreground: view.panel.dim
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.bodySmall
        onClicked: view.panel.setDefaultSpeed(view.panel.defaultSpeed - 0.1)
      }
      Text {
        textFormat: Text.PlainText
        width: Style.space(38)
        text: Model.speedLabel(view.panel.defaultSpeed)
        color: view.panel.fg
        font.family: view.panel.fontName
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }
      PanelActionButton {
        iconText: "+"
        foreground: view.panel.dim
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.bodySmall
        onClicked: view.panel.setDefaultSpeed(view.panel.defaultSpeed + 0.1)
      }
    }
  }

  Item {
    width: parent.width
    height: Style.space(30)

    Column {
      anchors.left: parent.left
      anchors.right: boostToggle.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        text: "Voice Boost"
        color: view.panel.fg
        font.family: view.panel.fontName
        font.pixelSize: Style.font.body
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "levels quiet talk against loud music and ads"
        color: view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    ToggleSwitch {
      id: boostToggle
      checked: view.panel.voiceBoost
      foreground: view.panel.fg
      accent: Color.accent
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      onToggled: view.panel.setVoiceBoost(!view.panel.voiceBoost)
    }
  }

  PanelSectionHeader {
    text: "FEEDS"
    foreground: view.panel.fg
    fontFamily: view.panel.fontName
  }

  Item {
    width: parent.width
    height: Style.space(30)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "Check every"
      color: view.panel.fg
      font.family: view.panel.fontName
      font.pixelSize: Style.font.body
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      PanelActionButton {
        iconText: "−"
        foreground: view.panel.dim
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.bodySmall
        onClicked: view.panel.setPollMinutes(view.panel.pollMinutes - 5)
      }
      Text {
        textFormat: Text.PlainText
        width: Style.space(54)
        text: view.panel.pollMinutes + " min"
        color: view.panel.fg
        font.family: view.panel.fontName
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }
      PanelActionButton {
        iconText: "+"
        foreground: view.panel.dim
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.bodySmall
        onClicked: view.panel.setPollMinutes(view.panel.pollMinutes + 5)
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: view.panel.shows.length + " show" + (view.panel.shows.length === 1 ? "" : "s")
      + " · polls are staggered and use conditional GET, so an unchanged feed "
      + "costs a couple of hundred bytes."
    color: view.panel.dim
    font.family: view.panel.fontName
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: view.panel.indexKey !== "" && view.panel.indexSecret !== ""
      ? "search: Podcast Index (API key configured)"
      : "search: iTunes directory — set podcastIndexKey/podcastIndexSecret to use Podcast Index instead"
    color: view.panel.dim
    font.family: view.panel.fontName
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    topPadding: Style.space(6)
    text: "settings live in this widget's own entry in ~/.config/omarchy/shell.json — "
      + "`omarchy bar set bottelet.podcasts pollMinutes 60`"
    color: view.panel.dim
    font.family: view.panel.fontName
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    horizontalAlignment: Text.AlignHCenter
  }
}
