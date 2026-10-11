import AppKit
import XCTest
@testable import NullPlayer

/// `BloomPostProcessor.apply` had no caller until the Equalizer Studio's Boutique faceplate, and the
/// first run hit three traps: a `.private` texture read back with `getBytes`, an upload blitted into a
/// texture of another pixel format, and an image built over a buffer that had already gone.
final class BloomPostProcessorTests: XCTestCase {
    func testBrightPixelsSpreadIntoTheirSurroundings() throws {
        let processor = BloomPostProcessor()
        try XCTSkipUnless(processor.isAvailable, "no Metal device")
        processor.threshold = 0.5
        processor.radius = 6
        processor.intensity = 1

        // Black, with a white square in the middle.
        let width = 64, height = 32
        let square = CGRect(x: 28, y: 12, width: 8, height: 8)
        let input = try XCTUnwrap(Self.image(width: width, height: height) { context in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(square)
        })

        let output = try XCTUnwrap(processor.apply(to: input))
        XCTAssertEqual(output.width, width)
        XCTAssertEqual(output.height, height)

        let pixels = try XCTUnwrap(Self.rgba(output))
        func red(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4] }
        // Just outside the square was black going in; the bloom has lit it.
        XCTAssertGreaterThan(red(Int(square.maxX) + 2, Int(square.midY)), 10)
        // Far from it, still black.
        XCTAssertLessThan(red(2, 2), 4)
        // The square itself stays white.
        XCTAssertGreaterThan(red(Int(square.midX), Int(square.midY)), 250)
    }

    private static func image(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context)
        return context.makeImage()
    }

    /// Top row first, RGBA8 premultiplied.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }
}
