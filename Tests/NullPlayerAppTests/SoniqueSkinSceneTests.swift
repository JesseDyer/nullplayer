import XCTest
@testable import NullPlayer

final class SoniqueSkinSceneTests: XCTestCase {
    /// A 40×30 navigator frame whose 120×60 drawer sits under it at 0,30 and slides 50 px down, with a knob
    /// at 100,5 and sliders 4×20 at 2,2, 5 apart (all in the drawer's own pixels).
    private func navigator(open: Bool) throws -> SoniqueSkinScene {
        var entries = SoniqueSkinFixture.complete
        entries[0] = ("/skin.ini", Data("""
            [misc locations]\r\nDRAWER_POS_x=0\r\nDRAWER_POS_y=30\r\n[misc values]\r\nMISC_DRAWER_DISTANCE_TOSLIDE=50\r
            MISC_DRAWER_SLIDER_ARRAY_POS_x=2\r\nMISC_DRAWER_SLIDER_ARRAY_POS_y=2\r\nMISC_DRAWER_SLIDER_SIZE_x=4\r
            MISC_DRAWER_SLIDER_SIZE_y=20\r\nMISC_DRAWER_SLIDER_PITCH=5\r\n
            """.utf8))
        // Nav regions are cut to the nav picture (`SQ0010`), so it is as large as the drawer.
        entries[1] = ("/jpeg/navigator", SoniqueSkinFixture.jpeg(width: 120, height: 60))
        entries += [("/rgn/nav/drawer", SoniqueSkinFixture.region([(0, 0, 120, 60)])),
                    ("/rgn/nav/dknobamp", SoniqueSkinFixture.region([(100, 5, 110, 15)]))]
        let skin = try SoniqueSkinLoader.load(data: SoniqueSkinFixture.sgf(entries))
        return SoniqueSkinScene(skin: skin, mode: .navigator, navDrawerOpen: open)
    }

    /// A point in skin pixels, as the scene hits canvas pixels.
    private func hit(_ scene: SoniqueSkinScene, _ x: Int, _ y: Int) -> SoniqueSkinControl? {
        scene.hit(x: x - scene.canvas.left, y: y - scene.canvas.top).control
    }

    func testTheOpenDrawerSlidesAndItsDialsAreHit() throws {
        let open = try navigator(open: true)
        XCTAssertEqual(hit(open, 4, 30 + 50 + 12), .eqSlider(0))
        XCTAssertEqual(hit(open, 2 + 3 * 5 + 1, 30 + 50 + 12), .eqSlider(3))
        XCTAssertEqual(hit(open, 105, 30 + 50 + 10), .amp)
        // The tab is a press the window acts on (it toggles the drawer), not chassis.
        XCTAssertTrue(SoniqueSkinControl.drawerTab.isActionable)
    }

    func testTheClosedDrawerHasNoDialsAndTheWindowKeepsRoomToOpen() throws {
        let closed = try navigator(open: false), open = try navigator(open: true)
        XCTAssertNil(hit(closed, 4, 30 + 12))
        XCTAssertNil(hit(closed, 105, 30 + 10))
        XCTAssertEqual(closed.canvas, open.canvas)
        XCTAssertEqual(closed.canvas.bottom, 30 + 50 + 60)
    }
}
