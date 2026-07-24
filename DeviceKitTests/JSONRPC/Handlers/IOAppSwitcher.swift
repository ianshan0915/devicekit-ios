import Foundation
import XCTest
import os

/// XCUIDevice's private low-level HID entry point. It injects a raw HID event and
/// returns immediately — unlike `press(.home)`, which blocks ~1-1.5s waiting for the
/// springboard animation to quiesce, far too slow to land two presses inside iOS's
/// ~300ms double-press window. This is the mechanism WebDriverAgent uses for its
/// button presses.
///
/// `perform(_:)` cannot reach it: that takes at most two *object* arguments, and these
/// are primitives. An @objc protocol existential is just the object pointer, so
/// `unsafeBitCast` onto this protocol is the standard way to call it from Swift.
@objc private protocol HIDEventDispatcher {
    @objc(_dispatchEventWithPage:usage:duration:)
    func dispatchEvent(page: UInt32, usage: UInt32, duration: Double)
}

struct IOAppSwitcherRequest: Codable {
    /// Milliseconds between the two home presses. iOS's double-press window is roughly
    /// 300ms, but the value that works through *synthetic* HID injection is empirical —
    /// exposing it as a param means tuning costs one request instead of a rebuild and a
    /// pass over every phone in the fleet.
    let gapMs: Int?
}

@MainActor
struct IOAppSwitcherMethodHandler: RPCMethodHandler {
    static let methodName = "device.io.appSwitcher"

    /// HID consumer page, and the Menu (home button) usage on it.
    private static let consumerPage: UInt32 = 0x0C
    private static let menuUsage: UInt32 = 0x40
    /// How long each synthetic press is held.
    private static let pressDuration = 0.005
    private static let defaultGapMs = 150
    private static let maxGapMs = 2000

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(IOAppSwitcherRequest.self, from: params)
        let gapMs = request.gapMs ?? Self.defaultGapMs
        // Bounds-check before the UInt64 conversion below: a negative value traps, and
        // a trap kills the runner process — which drops the whole session, not just
        // this call.
        guard gapMs >= 0, gapMs <= Self.maxGapMs else {
            throw RPCMethodError.invalidParams("gapMs must be between 0 and \(Self.maxGapMs)")
        }

        let selector = NSSelectorFromString("_dispatchEventWithPage:usage:duration:")
        guard XCUIDevice.shared.responds(to: selector) else {
            // Must not report success: from the host, a silent no-op is
            // indistinguishable from a working press. An error lets the host fall back
            // to the Face-ID swipe gesture.
            throw RPCMethodError.internalError(
                "XCUIDevice does not respond to _dispatchEventWithPage:usage:duration:"
            )
        }
        let device = unsafeBitCast(XCUIDevice.shared, to: HIDEventDispatcher.self)

        logger.info("[Start] app switcher: double home press, gap \(gapMs)ms")
        let start = Date()
        device.dispatchEvent(
            page: Self.consumerPage, usage: Self.menuUsage, duration: Self.pressDuration)
        try await Task.sleep(nanoseconds: UInt64(gapMs) * 1_000_000)
        device.dispatchEvent(
            page: Self.consumerPage, usage: Self.menuUsage, duration: Self.pressDuration)
        let duration = Date().timeIntervalSince(start)
        logger.info("[Done] app switcher took \(duration)")

        return .object(["success": .bool(true), "gapMs": .int(gapMs)])
    }
}
