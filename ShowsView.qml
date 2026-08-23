import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Subscriptions, directory search, add-by-URL and OPML — plus the per-show
// episode list you drill into.
Column {
  id: view

  required property var panel

  // Both hand keyboard focus back to the panel: submitting so the arrow keys
  // can walk the results that just arrived, dismissing so Escape gets you out
  // of the box without closing the panel.
  signal searchSubmitted()
  signal searchDismissed()

  readonly property bool searchActive: searchField.activeFocus

  // The one box is both a directory search and a filter over what you already
  // subscribe to: your shows narrow as you type, and anything you are not
  // subscribed to shows up underneath them. Both lists come off the panel so
  // the cursor and the delegates cannot disagree about what is on screen.
  readonly property var visibleShows: panel.matchingShows
  readonly property var directoryRows: panel.visibleResults

  function focusSearch() {
    searchField.forceActiveFocus()
  }

  function clearSearch() {
    searchField.text = ""
  }

  spacing: Style.space(6)

  // ================= subscription list =================

  Column {
    visible: view.panel.detailShowId === ""
    width: parent.width
    spacing: Style.space(6)

    TextField {
      id: searchField
      width: parent.width
      placeholderText: "search shows, or paste an RSS URL"
      foreground: view.panel.fg
      font.family: view.panel.fontName

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          view.panel.runSearch(text)
          view.searchSubmitted()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          text = ""
          view.panel.searchResults = []
          view.searchDismissed()
          event.accepted = true
        }
      }
      onTextChanged: view.panel.searchTerm = text
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        visible: view.panel.searching || view.panel.searchNote !== ""
        text: view.panel.searching ? "searching…" : view.panel.searchNote
        color: view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: Math.max(0, parent.width - opmlRow.implicitWidth - Style.space(6))
        anchors.verticalCenter: parent.verticalCenter
      }

      Row {
        id: opmlRow
        spacing: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
          model: [
            { label: "Import OPML", action: "import" },
            { label: "Export OPML", action: "export" }
          ]

          Rectangle {
            id: opmlButton
            required property var modelData

            width: opmlLabel.implicitWidth + Style.space(14)
            height: opmlLabel.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: opmlArea.containsMouse
              ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"
            border.width: 1
            border.color: view.panel.faint

            Text {
              id: opmlLabel
              anchors.centerIn: parent
              text: opmlButton.modelData.label
              color: view.panel.fg
              font.family: view.panel.fontName
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: opmlArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (opmlButton.modelData.action === "import") view.panel.importOpml()
                else view.panel.exportOpml()
              }
            }
          }
        }
      }
    }

    PanelSectionHeader {
      visible: view.panel.shows.length > 0
      text: "SUBSCRIBED — " + view.visibleShows.length
      foreground: view.panel.fg
      fontFamily: view.panel.fontName
    }

    Text {
      textFormat: Text.PlainText
      visible: view.panel.shows.length > 0 && view.visibleShows.length === 0
      width: parent.width
      text: "none of your " + view.panel.shows.length + " subscriptions match — clear the box to see them all"
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: view.visibleShows

      Item {
        id: showRow
        required property int index
        required property var modelData

        readonly property bool selected: view.panel.view === "shows"
          && view.panel.detailShowId === "" && view.panel.cursor === index

        width: parent.width
        height: Style.space(46)

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: showRow.selected || showArea.containsMouse
            ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"
          border.width: showRow.selected ? 1 : 0
          border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5)
        }

        Rectangle {
          id: showArt
          width: Style.space(34)
          height: width
          radius: Math.min(4, Style.cornerRadius)
          color: view.panel.faint
          clip: true
          anchors.left: parent.left
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter

          Image {
            anchors.fill: parent
            source: showRow.modelData.artPath ? "file://" + showRow.modelData.artPath : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 96
            sourceSize.height: 96
            visible: status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: !showRow.modelData.artPath
            text: ""
            color: view.panel.dim
            font.family: view.panel.fontName
            font.pixelSize: Style.font.bodySmall
          }
        }

        Column {
          anchors.left: showArt.right
          anchors.leftMargin: Style.space(8)
          anchors.right: showActions.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: showRow.modelData.title || showRow.modelData.feed
            color: view.panel.fg
            font.family: view.panel.fontName
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
          Row {
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: Model.modeLabel(showRow.modelData.mode)
              color: showRow.modelData.mode === "ignore" ? view.panel.dim : Color.accent
              font.family: view.panel.fontName
              font.pixelSize: Math.max(8, Style.font.caption - 1)
              font.bold: true
              font.letterSpacing: 1
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: showRow.modelData.count + " episodes"
                + (showRow.modelData.speed > 0 ? " · " + Model.speedLabel(showRow.modelData.speed) : "")
              color: view.panel.dim
              font.family: view.panel.fontName
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              visible: showRow.modelData.stale
              text: "· not updating"
              color: Color.urgent
              font.family: view.panel.fontName
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }

        Row {
          id: showActions
          anchors.right: parent.right
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          PanelActionButton {
            iconText: ""
            tooltipText: Model.modeHint(Model.nextMode(showRow.modelData.mode))
            foreground: view.panel.dim
            hoverColor: Color.accent
            fontFamily: view.panel.fontName
            fontSize: Math.max(8, Style.font.caption)
            onClicked: view.panel.cycleShowMode(showRow.modelData)
          }
          PanelActionButton {
            iconText: ""
            tooltipText: "Check this feed now"
            foreground: view.panel.dim
            hoverColor: Color.accent
            fontFamily: view.panel.fontName
            fontSize: Math.max(8, Style.font.caption)
            onClicked: view.panel.refreshShow(showRow.modelData.id)
          }
          PanelActionButton {
            iconText: ""
            tooltipText: "Unsubscribe"
            foreground: view.panel.dim
            hoverColor: Color.urgent
            fontFamily: view.panel.fontName
            fontSize: Math.max(8, Style.font.caption)
            onClicked: view.panel.unsubscribe(showRow.modelData.id)
          }
        }

        MouseArea {
          id: showArea
          anchors.fill: parent
          anchors.rightMargin: showActions.width + Style.space(8)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            view.panel.cursor = showRow.index
            view.panel.loadDetail(showRow.modelData.id)
          }
        }
      }
    }

    // ---- Directory results.
    Column {
      visible: view.directoryRows.length > 0
      width: parent.width
      spacing: Style.space(1)

      PanelSectionHeader {
        text: "NOT SUBSCRIBED"
        foreground: view.panel.fg
        fontFamily: view.panel.fontName
      }

      Repeater {
        model: view.directoryRows

        Item {
          id: resultRow
          required property int index
          required property var modelData

          readonly property bool selected: view.panel.view === "shows"
            && view.panel.detailShowId === ""
            && view.panel.cursor === view.visibleShows.length + index

          readonly property string artPath: modelData.artwork
            ? (view.panel.artPaths[modelData.artwork] || "") : ""

          width: parent.width
          height: Style.space(46)

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: resultRow.selected || resultArea.containsMouse
              ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"
            border.width: resultRow.selected ? 1 : 0
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5)
          }

          Rectangle {
            id: resultArt
            width: Style.space(34)
            height: width
            radius: Math.min(4, Style.cornerRadius)
            color: view.panel.faint
            clip: true
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter

            Image {
              anchors.fill: parent
              // Always a local file: the helper downloads and type-sniffs it
              // so the panel never reaches out to a directory API's CDN.
              source: resultRow.artPath ? "file://" + resultRow.artPath : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              sourceSize.width: 96
              sourceSize.height: 96
              visible: status === Image.Ready
            }

            Text {
              anchors.centerIn: parent
              visible: !resultRow.artPath
              text: ""
              color: view.panel.dim
              font.family: view.panel.fontName
              font.pixelSize: Style.font.bodySmall
            }
          }

          Column {
            anchors.left: resultArt.right
            anchors.leftMargin: Style.space(8)
            anchors.right: addLabel.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: resultRow.modelData.title
              color: view.panel.fg
              font.family: view.panel.fontName
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: resultRow.modelData.author
                + (resultRow.modelData.count > 0 ? " · " + resultRow.modelData.count + " episodes" : "")
              color: view.panel.dim
              font.family: view.panel.fontName
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Text {
            id: addLabel
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: "SUBSCRIBE"
            color: Color.accent
            font.family: view.panel.fontName
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
            opacity: resultRow.selected || resultArea.containsMouse ? 1 : 0.6
          }

          MouseArea {
            id: resultArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              view.panel.cursor = view.visibleShows.length + resultRow.index
              view.panel.subscribe(resultRow.modelData.feed)
            }
          }
        }
      }

      // Paging. Arrowing down past the last result does the same thing, so
      // this is the discoverable half of a keyboard gesture.
      Item {
        visible: view.panel.hiddenResults > 0
        width: parent.width
        height: visible ? Style.space(28) : 0

        Rectangle {
          anchors.fill: parent
          anchors.margins: Style.space(1)
          radius: Style.cornerRadius
          color: moreArea.containsMouse
            ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "show " + Math.min(view.panel.hiddenResults, view.panel.resultPageSize)
            + " more of " + view.panel.hiddenResults
          color: view.panel.dim
          font.family: view.panel.fontName
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: moreArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.panel.showMoreResults()
        }
      }
    }

    Column {
      visible: view.panel.shows.length === 0 && view.directoryRows.length === 0
      width: parent.width
      topPadding: Style.space(16)
      bottomPadding: Style.space(12)
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "no subscriptions yet"
        color: view.panel.fg
        font.family: view.panel.fontName
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "start typing above to search the directory — no account or API key "
          + "needed — or paste a show's RSS URL and press Enter, including a "
          + "private Patreon or Supercast feed."
        color: view.panel.dim
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }

  // ================= per-show episode list =================

  Column {
    visible: view.panel.detailShowId !== ""
    width: parent.width
    spacing: Style.space(4)

    Item {
      width: parent.width
      height: Style.space(26)

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: backRow.implicitWidth + Style.space(12)
        height: Style.space(20)
        radius: Style.cornerRadius
        color: backArea.containsMouse
          ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"

        Row {
          id: backRow
          anchors.centerIn: parent
          spacing: Style.space(4)

          Text {
            text: "‹"
            color: view.panel.dim
            font.family: view.panel.fontName
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: "SHOWS"
            color: view.panel.dim
            font.family: view.panel.fontName
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          id: backArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.panel.detailShowId = ""
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.left: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: view.panel.detailShow ? view.panel.detailShow.title : ""
        color: Qt.darker(view.panel.fg, 1.2)
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }
    }

    // ---- Per-show settings: mode, speed, feed link.
    BorderSurface {
      visible: !!view.panel.detailShow
      width: parent.width
      implicitHeight: showSettings.implicitHeight + Style.space(16)
      radius: Style.cornerRadius
      color: "transparent"
      borderSpec: Border.flat(view.panel.faint, 1)

      Column {
        id: showSettings
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(8)
        spacing: Style.space(4)

        Item {
          width: parent.width
          height: modeRow.implicitHeight

          Row {
            id: modeRow
            anchors.left: parent.left
            spacing: Style.space(6)

            Repeater {
              model: Model.MODES

              Rectangle {
                id: modePill
                required property var modelData

                readonly property bool selected: view.panel.detailShow
                  && view.panel.detailShow.mode === modelData

                width: modeText.implicitWidth + Style.space(16)
                height: modeText.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: selected || modeArea.containsMouse
                  ? Style.hoverFillFor(view.panel.fg, Color.accent) : "transparent"
                border.width: 1
                border.color: selected
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.9)
                  : view.panel.faint

                Text {
                  id: modeText
                  anchors.centerIn: parent
                  text: Model.modeLabel(modePill.modelData)
                  color: modePill.selected
                    ? Style.hoverStateColor(view.panel.fg, Color.accent) : view.panel.fg
                  font.family: view.panel.fontName
                  font.pixelSize: Math.max(8, Style.font.caption)
                  font.bold: modePill.selected
                  font.letterSpacing: 1
                }

                MouseArea {
                  id: modeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: view.panel.setShowMode(view.panel.detailShow, modePill.modelData)
                }
              }
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            PanelActionButton {
              iconText: "−"
              tooltipText: "Slower for this show"
              foreground: view.panel.dim
              hoverColor: Color.accent
              fontFamily: view.panel.fontName
              fontSize: Style.font.bodySmall
              onClicked: view.panel.stepShowSpeed(view.panel.detailShow, -0.1)
            }
            Text {
              textFormat: Text.PlainText
              width: Style.space(34)
              text: view.panel.detailShow && view.panel.detailShow.speed > 0
                ? Model.speedLabel(view.panel.detailShow.speed)
                : Model.speedLabel(view.panel.defaultSpeed)
              color: view.panel.detailShow && view.panel.detailShow.speed > 0
                ? Color.accent : view.panel.dim
              font.family: view.panel.fontName
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              anchors.verticalCenter: parent.verticalCenter
            }
            PanelActionButton {
              iconText: "+"
              tooltipText: "Faster for this show"
              foreground: view.panel.dim
              hoverColor: Color.accent
              fontFamily: view.panel.fontName
              fontSize: Style.font.bodySmall
              onClicked: view.panel.stepShowSpeed(view.panel.detailShow, 0.1)
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: view.panel.detailShow ? Model.modeHint(view.panel.detailShow.mode) : ""
          color: view.panel.dim
          font.family: view.panel.fontName
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: !!(view.panel.detailShow && view.panel.detailShow.lastError)
          width: parent.width
          text: view.panel.detailShow
            ? "last check failed: " + view.panel.detailShow.lastError : ""
          color: Color.urgent
          font.family: view.panel.fontName
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    Repeater {
      model: view.panel.detailEpisodes

      EpisodeRow {
        required property int index
        required property var modelData

        panel: view.panel
        episode: modelData
        showName: false
        showArtwork: false
        selected: view.panel.view === "shows"
          && view.panel.detailShowId !== "" && view.panel.cursor === index
        trailingIcon: modelData.state === "archived" ? "" : ""
        trailingTooltip: modelData.state === "archived" ? "Restore to inbox" : "Archive"

        onActivated: {
          view.panel.cursor = index
          view.panel.enqueueEpisode(modelData, false)
          view.panel.note("queued · " + modelData.title)
        }
        onSecondary: {
          view.panel.cursor = index
          view.panel.playEpisode(modelData, {})
        }
        onTrailingClicked: {
          if (modelData.state === "archived") view.panel.unarchiveEpisode(modelData)
          else view.panel.archiveEpisode(modelData)
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: view.panel.detailEpisodes.length === 0
      width: parent.width
      topPadding: Style.space(12)
      text: "loading episodes…"
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
