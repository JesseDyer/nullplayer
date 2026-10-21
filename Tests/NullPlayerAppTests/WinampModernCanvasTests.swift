import CoreGraphics
import XCTest
@testable import NullPlayer

/// The `.wal` window's canvas: a partial frame lands exactly where a whole one would, and a frame
/// reports an outline only when it changed the canvas's alpha.
final class WinampModernCanvasTests: XCTestCase {
    private let width = 40, height = 30
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A scene of solid rects, recorded in pixels.
    private func scene(_ rects: [(CGRect, CGColor)]) -> WasabiDrawList {
        let list = WasabiDrawList(ctm: .identity, clip: CGRect(x: 0, y: 0, width: width, height: height))
        for (rect, color) in rects {
            list.setFillColor(color)
            list.fill(rect)
        }
        return list
    }

    private func job(_ scene: WasabiDrawList, rects: [CGRect]? = nil, width: Int? = nil) -> WinampModernCanvas.Job {
        let width = width ?? self.width
        return WinampModernCanvas.Job(
            pixelWidth: width, pixelHeight: height, colorSpace: space, scale: 1,
            rects: rects ?? [CGRect(x: 0, y: 0, width: width, height: height)],
            scene: scene, chrome: nil, promotesAlpha: false)
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    func testAPartialFrameMatchesAWholeOne() throws {
        let before = scene([(CGRect(x: 0, y: 0, width: 40, height: 30), red)])
        let after = scene([(CGRect(x: 0, y: 0, width: 40, height: 30), red),
                           (CGRect(x: 10, y: 10, width: 8, height: 6), blue)])
        let partial = WinampModernCanvas()
        _ = partial.render(job(before))
        let patched = try XCTUnwrap(partial.render(job(after, rects: [CGRect(x: 8, y: 8, width: 12, height: 10)])))
        let whole = try XCTUnwrap(WinampModernCanvas().render(job(after)))
        XCTAssertEqual(bytes(patched.picture), bytes(whole.picture))
    }

    func testAFrameThatKeepsTheAlphaReportsNoOutline() throws {
        let canvas = WinampModernCanvas()
        let first = try XCTUnwrap(canvas.render(job(scene([(CGRect(x: 5, y: 5, width: 20, height: 10), red)]))))
        XCTAssertNotNil(first.outline, "a new canvas's first frame changes its alpha")
        // A recolour inside the same shape: a readout tick.
        let recolour = try XCTUnwrap(canvas.render(job(scene([(CGRect(x: 5, y: 5, width: 20, height: 10), blue)]),
                                                       rects: [CGRect(x: 5, y: 5, width: 20, height: 10)])))
        XCTAssertNil(recolour.outline)
    }

    func testAFrameThatMovesTheShapeReportsTheOutline() throws {
        let canvas = WinampModernCanvas()
        _ = canvas.render(job(scene([(CGRect(x: 5, y: 5, width: 20, height: 10), red)])))
        let grown = try XCTUnwrap(canvas.render(job(scene([(CGRect(x: 5, y: 5, width: 30, height: 10), red)]),
                                                    rects: [CGRect(x: 25, y: 5, width: 10, height: 10)])))
        let outline = try XCTUnwrap(grown.outline)
        XCTAssertEqual(outline.width, width)
        XCTAssertEqual(outline.height, height)
    }

    func testANewSizeIsAFreshCanvas() {
        let canvas = WinampModernCanvas()
        XCTAssertTrue(canvas.isFresh(pixelWidth: width, pixelHeight: height, colorSpace: space))
        _ = canvas.render(job(scene([])))
        XCTAssertFalse(canvas.isFresh(pixelWidth: width, pixelHeight: height, colorSpace: space))
        XCTAssertTrue(canvas.isFresh(pixelWidth: width + 1, pixelHeight: height, colorSpace: space))
        XCTAssertTrue(canvas.isFresh(pixelWidth: width, pixelHeight: height,
                                     colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!))
    }
}
