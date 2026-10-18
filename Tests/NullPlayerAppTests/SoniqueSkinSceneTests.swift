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

    /// A navigator whose 301×228 display sits at 10,20.
    private func console(_ screen: SoniqueSkinNavScreen) throws -> SoniqueSkinScene {
        var entries = SoniqueSkinFixture.complete
        entries[1] = ("/jpeg/navigator", SoniqueSkinFixture.jpeg(width: 320, height: 260))
        entries[2] = ("/rgn/nav/frame", SoniqueSkinFixture.region([(0, 0, 320, 260)]))
        entries.append(("/rgn/nav/display", SoniqueSkinFixture.region([(10, 20, 311, 248)])))
        let skin = try SoniqueSkinLoader.load(data: SoniqueSkinFixture.sgf(entries))
        return SoniqueSkinScene(skin: skin, mode: .navigator, navScreen: screen)
    }

    func testTheMenuScreenHitsItsItemsFromTheDisplayCorner() throws {
        let menu = try console(.menu)
        XCTAssertEqual(hit(menu, 10 + 50, 20 + 80), .menu(.visualMode))
        XCTAssertEqual(hit(menu, 10 + 30, 20 + 178), .menu(.setup))
        XCTAssertEqual(hit(menu, 10 + 230, 20 + 47), .menu(.spectrum))
        XCTAssertEqual(hit(menu, 10 + 230, 20 + 142), .menu(.about))
        XCTAssertFalse(menu.balls.contains(.back))
    }

    func testAnotherScreenHasNoMenuItemsAndABackBall() throws {
        let screen = try console(.visualMode)
        XCTAssertNil(hit(screen, 10 + 50, 20 + 80))
        XCTAssertEqual(screen.balls.first, .back)
        let back = try XCTUnwrap(screen.ballRects.first?.1), next = try XCTUnwrap(screen.ballRects.dropFirst().first?.1)
        XCTAssertEqual(next.left - back.left, 12)
    }

    func testTheClosedDrawerHasNoDialsAndTheWindowKeepsRoomToOpen() throws {
        let closed = try navigator(open: false), open = try navigator(open: true)
        XCTAssertNil(hit(closed, 4, 30 + 12))
        XCTAssertNil(hit(closed, 105, 30 + 10))
        XCTAssertEqual(closed.canvas, open.canvas)
        XCTAssertEqual(closed.canvas.bottom, 30 + 50 + 60)
    }
}
