import XCTest
@testable import NullPlayer

/// `System` methods the S4 demand queue ranked, and events called as methods (B182, B183, B186, B187, B188, B191, B194, B196, B197,
/// B199, B200). Each was a call that aborted
/// the whole handler it sat in.
final class WinampModernSystemDemandTests: XCTestCase {

    /// B188: a skin's scripted transport buttons reach the host's next and previous.
    func testNextAndPreviousReachTheHost() throws {
        let host = TransportHost()
        let (runtime, program) = try makeRuntime(host: host)
        _ = try system(runtime, program, "next")
        _ = try system(runtime, program, "next")
        _ = try system(runtime, program, "previous")
        XCTAssertEqual(host.calls, ["next", "next", "previous"])
    }

    /// B191: a code point to its one-character string; a value that is no scalar answers empty.
    func testChrIsOneCharacter() throws {
        let (runtime, program) = try makeRuntime()
        XCTAssertEqual(try system(runtime, program, "chr", [.integer(92)]).stringValue, "\\")
        XCTAssertEqual(try system(runtime, program, "chr", [.integer(232)]).stringValue, "è")
        XCTAssertEqual(try system(runtime, program, "chr", [.integer(0xD800)]).stringValue, "")
    }

    /// B196: the clock fields of a `getDate()` stamp, and of now when the stamp is 0.
    func testDateFieldsReadTheStamp() throws {
        let (runtime, program) = try makeRuntime()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: stamp)
        let argument = [MakiValue.integer(1_700_000_000)]
        XCTAssertEqual(try system(runtime, program, "getDateHour", argument).integerValue, Int32(parts.hour!))
        XCTAssertEqual(try system(runtime, program, "getDateMin", argument).integerValue, Int32(parts.minute!))
        XCTAssertEqual(try system(runtime, program, "getDateSec", argument).integerValue, Int32(parts.second!))
        let hourNow = try system(runtime, program, "getDateHour", [.integer(0)]).integerValue
        XCTAssertTrue((0..<24).contains(hourNow))
    }

    /// B200: null and a vanished graph object are invalid; a live one is valid.
    func testIsObjectValidResolvesTheReference() throws {
        let (runtime, program) = try makeRuntime()
        let layout = try XCTUnwrap(runtime.loadedSkin.runtime.graph.roots.first?.children.first)
        XCTAssertEqual(try system(runtime, program, "isObjectValid", [runtime.objectValue(layout)]).truthy, true)
        XCTAssertEqual(try system(runtime, program, "isObjectValid", [.null]).truthy, false)
        let gone = MakiValue.object(MakiObjectReference(.gui(WasabiObjectID(rawValue: 9_999))))
        XCTAssertEqual(try system(runtime, program, "isObjectValid", [gone]).truthy, false)
    }

    /// B183, B186, B187, B194, B197, B199: the host-action methods reach the host, each the way the
    /// matching skin action or menu does.
    func testHostActionMethodsReachTheHost() throws {
        let host = TransportHost()
        let (runtime, program) = try makeRuntime(host: host)
        var requests: [String] = []
        runtime.actionRequested = { action, _ in requests.append(action) }
        runtime.applicationRaiseRequested = { requests.append($0 ? "restore" : "activate") }
        runtime.windowMenuRequested = { requests.append("windowmenu") }
        runtime.equalizerEnabledSetterRequested = { requests.append("eq \($0)") }
        for method in ["eject", "minimizeApplication", "shutdown", "restoreApplication",
                       "activateApplication", "windowMenu"] {
            _ = try system(runtime, program, method)
        }
        _ = try system(runtime, program, "setEq", [.integer(1)])
        _ = try system(runtime, program, "setEq", [.integer(0)])
        XCTAssertEqual(host.calls, ["openFiles"])
        XCTAssertEqual(requests, ["MINIMIZE", "CLOSE", "restore", "activate", "windowmenu", "eq true", "eq false"])
    }

    /// `shutdown` has an arity only on `Application`, so another class declaring the verb is not given it.
    func testShutdownIsGatedToApplication() throws {
        let (runtime, _) = try makeRuntime()
        // The interpreter passes the GUID in bytecode word order; `canonical` is its own inverse.
        let bytecodeGUID = MakiClassGUID.canonical(MakiClassGUID.application)
        XCTAssertNotNil(runtime.signature(for: "Shutdown", classGUID: bytecodeGUID))
        XCTAssertNil(runtime.signature(for: "shutdown", classGUID: nil))
    }

    /// B182: the thirteen events scripts call as methods have their `std.mi` arity, and the three
    /// names another class declares with a different arity get that one on that class.
    func testEventsCalledAsMethodsHaveTheirDeclaredArity() throws {
        let (runtime, _) = try makeRuntime()
        let arities = ["onLeftButtonDown": 2, "onLeftButtonUp": 2, "onRightButtonDown": 2,
                       "onRightButtonUp": 2, "onMouseMove": 2, "onNotify": 4, "onEqChanged": 1,
                       "onInfoChange": 1, "onSwitchToLayout": 1, "onPlay": 0, "onStop": 0,
                       "onAccelerator": 1, "onFrame": 1]
        for (event, arity) in arities {
            XCTAssertEqual(runtime.signature(for: event, classGUID: nil)?.argumentCount, arity, event)
        }
        let bytecode = MakiClassGUID.canonical
        XCTAssertEqual(runtime.signature(for: "onNotify", classGUID: bytecode(MakiClassGUID.wac))?.argumentCount, 3)
        XCTAssertEqual(runtime.signature(for: "onAccelerator", classGUID: bytecode(MakiClassGUID.system))?.argumentCount, 3)
        XCTAssertEqual(runtime.signature(for: "onFrame", classGUID: bytecode(MakiClassGUID.vis))?.argumentCount, 0)
    }

    // MARK: - Helpers

    private static let syntheticProgram = MakiProgram(
        version: 0x0403, classes: [], methods: [], variables: [], bindings: [], instructions: [],
        source: WalSourceLocation(path: "/Skins/Synthetic/t.maki"), ownerID: nil, parameter: nil)

    private func system(_ runtime: WinampModernScriptRuntime, _ program: MakiProgram,
                        _ method: String, _ arguments: [MakiValue] = []) throws -> MakiValue {
        try runtime.invoke(method: method, on: MakiObjectReference(.system), arguments: arguments, program: program)
    }

    private func makeRuntime(host: WinampModernHost = WinampModernStubHost()) throws
        -> (WinampModernScriptRuntime, MakiProgram) {
        let loaded = try makeWinampModernSkin(xml: """
        <WasabiXML><container id="main"><layout id="normal" w="16" h="16"/></container></WasabiXML>
        """)
        let runtime = try WinampModernScriptRuntime(loadedSkin: loaded, host: host)
        addTeardownBlock { runtime.teardown() }
        return (runtime, Self.syntheticProgram)
    }

    private final class TransportHost: WinampModernHost {
        var playbackState: PlaybackState = .stopped
        var currentTime: TimeInterval = 0
        var duration: TimeInterval = 0
        var volume: Double = 0.5
        var shuffleEnabled = false
        var repeatEnabled = false
        var trackTitle = ""
        var trackInfo = ""
        var spectrumLevels: [Float] = []
        var calls: [String] = []

        func play() {}
        func pause() {}
        func stop() {}
        func previous() { calls.append("previous") }
        func next() { calls.append("next") }
        func seek(to seconds: TimeInterval) {}
        func openFiles() { calls.append("openFiles") }
        func beginVisualizationConsumption() {}
        func endVisualizationConsumption() {}
    }
}
