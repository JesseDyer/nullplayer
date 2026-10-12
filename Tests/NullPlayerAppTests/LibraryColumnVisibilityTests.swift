import XCTest
@testable import NullPlayer

final class LibraryColumnVisibilityTests: XCTestCase {
    private struct TestColumn {
        let id: String
    }

    func testNormalizedIdsFiltersUnknownIdsDeduplicatesAndRestoresTitle() {
        let ids = LibraryColumnVisibility.normalizedIds(
            ["genre", "unknown", "genre", "rating"],
            allIds: ["title", "artist", "genre", "rating"]
        )

        XCTAssertEqual(ids, ["title", "genre", "rating"])
    }

    func testNormalizedIdsPreservesExistingTitlePosition() {
        let ids = LibraryColumnVisibility.normalizedIds(
            ["genre", "title", "artist"],
            allIds: ["title", "artist", "genre"]
        )

        XCTAssertEqual(ids, ["genre", "title", "artist"])
    }

    func testVisibleColumnsReturnsNormalizedColumnsInVisibleOrder() {
        let columns = [
            TestColumn(id: "title"),
            TestColumn(id: "artist"),
            TestColumn(id: "album"),
            TestColumn(id: "rating")
        ]

        let visible = LibraryColumnVisibility.visibleColumns(
            allColumns: columns,
            visibleIds: ["rating", "missing", "artist", "rating"],
            id: { $0.id }
        )

        XCTAssertEqual(visible.map(\.id), ["title", "rating", "artist"])
    }

    func testHeaderGroupFollowsTheMostDetailedExpandedRows() {
        // Artists tab: collapsed, an artist expanded, then one of its albums expanded.
        XCTAssertEqual(LibraryColumnVisibility.headerGroup([.artist, .artist]), .artist)
        XCTAssertEqual(LibraryColumnVisibility.headerGroup([.artist, .album, .artist]), .album)
        XCTAssertEqual(LibraryColumnVisibility.headerGroup([.artist, .album, .track, .album]), .track)
    }

    func testHeaderGroupIgnoresRowsWithoutSharedColumns() {
        // Plists tab: playlist rows carry no columns, their tracks do. YouTube rows keep their own.
        XCTAssertEqual(LibraryColumnVisibility.headerGroup([nil, .track, nil]), .track)
        XCTAssertEqual(LibraryColumnVisibility.headerGroup([.youtube, nil]), nil)
    }

    func testColumnVisibilityGroupMenuLabelsMatchUserFacingSections() {
        XCTAssertEqual(LibraryColumnVisibilityGroup.artist.headerTitle, "Artist columns")
        XCTAssertEqual(LibraryColumnVisibilityGroup.album.headerTitle, "Album columns")
        XCTAssertEqual(LibraryColumnVisibilityGroup.track.headerTitle, "Track columns")
        XCTAssertEqual(LibraryColumnVisibilityGroup.artist.resetTitle, "Reset Artist Columns")
        XCTAssertEqual(LibraryColumnVisibilityGroup.album.resetTitle, "Reset Album Columns")
        XCTAssertEqual(LibraryColumnVisibilityGroup.track.resetTitle, "Reset Track Columns")
    }

    func testChannelSortValueMapsFormattedLabelsToComparableChannelCounts() {
        XCTAssertEqual(LibraryColumnVisibility.channelSortValue("Mono"), 1)
        XCTAssertEqual(LibraryColumnVisibility.channelSortValue("Stereo"), 2)
        XCTAssertEqual(LibraryColumnVisibility.channelSortValue("5.1"), 6)
        XCTAssertEqual(LibraryColumnVisibility.channelSortValue("7.1"), 8)
        XCTAssertEqual(LibraryColumnVisibility.channelSortValue("10ch"), 10)
    }

    /// #542: under track columns the `#` cell (about 34 pt with the pad) already puts a track right of
    /// its album, so a two-deep track gets no extra indent, while an artist or album row, which has
    /// nothing for `#`, starts its title at the pad or its own indent.
    func testTitleOffsetIndentsOnlyByWhatTheLeadingCellsLeaveShort() {
        func offset(_ cell: CGFloat, _ indent: CGFloat, spans: Bool) -> CGFloat {
            LibraryColumnVisibility.titleOffset(cellOffset: cell, leadingPad: 4, indent: indent, spansLeadingCells: spans)
        }
        XCTAssertEqual(offset(34, 32, spans: false), 34, "a track's # cell already covers its indent")
        XCTAssertEqual(offset(34, 64, spans: false), 64, "a deep folder track still indents past it")
        XCTAssertEqual(offset(34, 0, spans: true), 4, "an artist row under track columns stays at the pad")
        XCTAssertEqual(offset(34, 16, spans: true), 16, "an album row keeps its own indent")
        XCTAssertEqual(offset(4, 0, spans: false), 4, "a title first in its row is unchanged")
    }
}
