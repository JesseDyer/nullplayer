import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NullPlayer

// The Sonique render probe: every mode of every skin through `SoniqueSkinRenderer`, the window's own
// draw path, written as `<out>/<skin>__<nav|mid|small>.png` at one skin pixel per pixel. Flags in
// `skills/sonique-skin-guide/reference/harness.md`.
final class SoniqueSkinRenderProbeTests: XCTestCase {
    func testRenderSkinOrCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SONIQUE_SKIN"], !path.isEmpty, let out = env["SONIQUE_RENDER_OUT"], !out.isEmpty else {
            throw XCTSkip("Set SONIQUE_SKIN and SONIQUE_RENDER_OUT. See skills/sonique-skin-guide/reference/harness.md.")
        }
        let skins = SoniqueSkinCensusTests.skins(at: path)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        // `SONIQUE_RENDER_STATE=playing` draws the lit play/stop, shuffle and repeat, small mode's
        // open drawer and half-filled lines at full volume; the default is the oracle's state:
        // stopped, track 1 loaded, its knobs at their first frame (the prefix has no sound device).
        let playing = env["SONIQUE_RENDER_STATE"] == "playing"
        var host = SoniqueSkinHostState(volume: 0, trackNumber: 1, title: "05 - Bella Ciao.mp3")
        if playing {
            host.volume = 1
            host.playState = .playing
            host.shuffle = true
            host.repeatAll = true
            host.songProgress = 0.5
            host.listProgress = 0.5
            host.elapsedSeconds = 3_923
            host.blinkersLit = true
        }
        var rendered = 0
        for file in skins {
            let name = file.deletingPathExtension().lastPathComponent
            guard let skin = try? SoniqueSkinLoader.load(contentsOf: file) else {
                HarnessOutput.emit("RENDER \(name) FAILED")
                continue
            }
            for (mode, tag) in [(SoniqueSkin.Mode.navigator, "nav"), (.mid, "mid"), (.small, "small")] {
                let scene = SoniqueSkinScene(skin: skin, mode: mode, host: host, smallDrawer: playing ? .top : nil)
                guard let image = SoniqueSkinRenderer.render(scene) else {
                    HarnessOutput.emit("RENDER \(name) \(tag) EMPTY")
                    continue
                }
                let url = URL(fileURLWithPath: out).appendingPathComponent("\(name)__\(tag).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                HarnessOutput.emit("RENDER \(name) \(tag) \(image.width)x\(image.height) origin=\(scene.canvas.left),\(scene.canvas.top)")
                rendered += 1
            }
        }
        HarnessOutput.emit("RENDERED \(rendered) of \(skins.count * 3)")
    }
}
