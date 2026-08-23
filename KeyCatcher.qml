import QtQuick

// qs.Ui.PanelKeyCatcher's contract, plus the two things a queue needs that
// the shared one deliberately does not carry:
//
//   * modifier-aware movement — Shift+Up/Down reorders the queue rather than
//     moving the cursor, and the shared catcher swallows arrows before any
//     ancestor can see the modifier;
//   * digitKey — 1..4 jump straight to a view.
//
// Signal names and default bindings are kept identical to the shell's so the
// muscle memory carries over from the sibling plugins.
Item {
  id: root

  property bool blocked: false

  signal moveRequested(int dx, int dy)
  signal reorderRequested(int direction)
  signal activateRequested()
  signal returnRequested()
  signal closeRequested()
  signal deleteRequested()
  signal tabRequested(int direction)
  signal textKey(string text)
  signal digitKey(int digit)

  focus: true
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (blocked) return

    var shift = (event.modifiers & Qt.ShiftModifier) !== 0

    if (event.key === Qt.Key_Escape) {
      closeRequested(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      tabRequested(shift || event.key === Qt.Key_Backtab ? -1 : 1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
      var down = event.key === Qt.Key_Down
      if (shift) reorderRequested(down ? 1 : -1)
      else moveRequested(0, down ? 1 : -1)
      event.accepted = true
      return
    }
    if (event.text === "j") { moveRequested(0, 1); event.accepted = true; return }
    if (event.text === "k") { moveRequested(0, -1); event.accepted = true; return }
    if (event.text === "J") { reorderRequested(1); event.accepted = true; return }
    if (event.text === "K") { reorderRequested(-1); event.accepted = true; return }
    if (event.key === Qt.Key_Right) { moveRequested(1, 0); event.accepted = true; return }
    if (event.key === Qt.Key_Left) { moveRequested(-1, 0); event.accepted = true; return }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      returnRequested(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Space) {
      activateRequested(); event.accepted = true; return
    }
    if (event.text === "x" || event.text === "X") {
      deleteRequested(); event.accepted = true; return
    }
    if (event.text && event.text.length === 1) {
      if (event.text >= "1" && event.text <= "9") {
        digitKey(parseInt(event.text, 10))
        event.accepted = true
        return
      }
      textKey(event.text)
    }
  }
}
