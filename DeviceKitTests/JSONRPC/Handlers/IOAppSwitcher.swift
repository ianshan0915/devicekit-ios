import Foundation
import XCTest
import os

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

        logger.info("[Start] app switcher: double home press, gap \(gapMs)ms")
        let start = Date()
        try dispatchHomePress()
        try await Task.sleep(nanoseconds: UInt64(gapMs) * 1_000_000)
        try dispatchHomePress()
        let duration = Date().timeIntervalSince(start)
        logger.info("[Done] app switcher took \(duration)")

        return .object(["success": .bool(true), "gapMs": .int(gapMs)])
    }

    /// Builds a low-level XCDeviceEvent and dispatches it directly. Going through
    /// XCUIDevice.performDeviceEvent or XCTRunnerDaemonSession waits for the current
    /// gesture to complete, which spaces two presses too far apart (or rejects the
    /// second); XCDeviceEvent.dispatch sends the HID event without that gate.
    private func dispatchHomePress() throws {
        guard let eventClass = NSClassFromString("XCDeviceEvent") else {
            throw RPCMethodError.internalError("XCDeviceEvent class is unavailable")
        }
        let makeSelector = NSSelectorFromString("deviceEventWithPage:usage:duration:")
        guard eventClass.responds(to: makeSelector) else {
            throw RPCMethodError.internalError(
                "XCDeviceEvent does not respond to deviceEventWithPage:usage:duration:"
            )
        }
        typealias MakeEvent = @convention(c) (
            AnyClass, Selector, UInt32, UInt32, Double
        ) -> NSObject
        let makeEvent = unsafeBitCast(
            eventClass.method(for: makeSelector),
            to: MakeEvent.self
        )
        let event = makeEvent(
            eventClass,
            makeSelector,
            Self.consumerPage,
            Self.menuUsage,
            Self.pressDuration
        )

        let dispatchSelector = NSSelectorFromString("dispatch")
        guard event.responds(to: dispatchSelector) else {
            throw RPCMethodError.internalError(
                "XCDeviceEvent does not respond to dispatch"
            )
        }
        typealias DispatchEvent = @convention(c) (NSObject, Selector) -> Void
        let dispatchEvent = unsafeBitCast(
            event.method(for: dispatchSelector),
            to: DispatchEvent.self
        )
        dispatchEvent(event, dispatchSelector)
    }
}
