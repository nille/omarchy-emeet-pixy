// Wheel routing for the pan/tilt/zoom rows.
//
// Pinned as a test because the intuitive answer is wrong, and because getting it
// wrong has a nasty failure mode: a scroll gesture aimed at the panel silently
// moves the camera instead.
//
// PanelSlider (a shared qs.Ui component, so not editable from this plugin) adjusts
// its value on wheel from an internal MouseArea. AxisRow stacks a second,
// button-less MouseArea on top to claim the wheel and scroll the panel instead.
// This file asserts the two things that arrangement depends on:
//
//   1. the interceptor wins the wheel, and the slider never sees it;
//   2. it does NOT swallow press/drag/right-click, which the slider still needs.
//
// A WheelHandler is the more natural-looking fix and does not work: a MouseArea
// beats a sibling WheelHandler regardless of declaration order. That is asserted
// too, so nobody "simplifies" this back into a version that reintroduces the bug.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
//
// Note: /usr/bin/qmltestrunner is Qt5 on Arch and exits silently on these files.
// The Qt6 binary under /usr/lib/qt6/bin is the one that works.
import QtQuick
import QtTest

Item {
  id: fixture
  width: 300
  height: 100

  // Appended to by every handler, so a test can assert not just who fired but
  // who did not — "the slider also moved" is the bug, and it is invisible if you
  // only check that scrolling happened.
  property string hits: ""

  // Mirrors AxisRow: the slider's MouseArea, with the wheel interceptor stacked
  // over it.
  Item {
    id: row
    anchors.fill: parent

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onWheel: function(wheel) { fixture.hits += "slider-wheel;" }
      onPressed: function(mouse) { fixture.hits += "slider-press;" }
      onReleased: function(mouse) { fixture.hits += "slider-release;" }
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) fixture.hits += "slider-right;"
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      onWheel: function(wheel) { fixture.hits += "scroll;" }
    }
  }

  // The arrangement that looks right and is not, kept as a control.
  Item {
    id: handlerRow
    anchors.fill: parent
    visible: false

    MouseArea {
      anchors.fill: parent
      onWheel: function(wheel) { fixture.hits += "handler-slider;" }
    }

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(event) { fixture.hits += "handler-scroll;" }
    }
  }

  TestCase {
    name: "AxisRowWheel"
    when: windowShown

    function init() { fixture.hits = "" }

    function test_wheel_scrolls_and_never_reaches_the_slider() {
      mouseWheel(row, 150, 50, 0, -120)
      compare(fixture.hits, "scroll;",
              "the wheel must scroll the panel and must not adjust the slider")
    }

    function test_wheel_up_behaves_the_same() {
      mouseWheel(row, 150, 50, 0, 120)
      compare(fixture.hits, "scroll;", "direction must not change who handles the wheel")
    }

    function test_drag_still_reaches_the_slider() {
      // The interceptor takes no buttons, so dragging the handle must be
      // unaffected — otherwise the fix trades one broken control for another.
      mousePress(row, 100, 50, Qt.LeftButton)
      mouseMove(row, 140, 50)
      mouseRelease(row, 140, 50, Qt.LeftButton)
      verify(fixture.hits.indexOf("slider-press;") >= 0,
             "press must reach the slider, got: " + fixture.hits)
      verify(fixture.hits.indexOf("slider-release;") >= 0,
             "release must reach the slider, got: " + fixture.hits)
    }

    function test_right_click_still_reaches_the_slider() {
      mouseClick(row, 100, 50, Qt.RightButton)
      verify(fixture.hits.indexOf("slider-right;") >= 0,
             "right-click must reach the slider, got: " + fixture.hits)
    }

    function test_a_wheelhandler_would_lose_to_the_slider() {
      // Documents why the fix is a MouseArea. If a future Qt makes the handler
      // win, this fails and the comment in Panel.qml can be revisited.
      handlerRow.visible = true
      row.visible = false
      mouseWheel(handlerRow, 150, 50, 0, -120)
      row.visible = true
      handlerRow.visible = false
      compare(fixture.hits, "handler-slider;",
              "a sibling WheelHandler loses to MouseArea.onWheel — hence the MouseArea")
    }
  }
}
