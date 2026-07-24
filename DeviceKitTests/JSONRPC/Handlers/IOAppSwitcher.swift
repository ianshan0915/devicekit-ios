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
        let firstCompletion = try dispatchHomePress()
        try await Task.sleep(nanoseconds: UInt64(gapMs) * 1_000_000)
        let secondCompletion = try dispatchHomePress()
        for try await _ in firstCompletion {}
        for try await _ in secondCompletion {}
        let duration = Date().timeIntervalSince(start)
        logger.info("[Done] app switcher took \(duration)")

        return .object(["success": .bool(true), "gapMs": .int(gapMs)])
    }

    /// Builds the same low-level XCDeviceEvent that WebDriverAgent uses, then enqueues
    /// it through XCTest's asynchronous daemon-session API. The returned stream finishes
    /// when delivery completes, but the caller deliberately enqueues both presses before
    /// awaiting either completion so they land inside iOS's double-press window.
    private func dispatchHomePress() throws -> AsyncThrowingStream<Void, Error> {
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

        guard let sessionClass = NSClassFromString("XCTRunnerDaemonSession") else {
            throw RPCMethodError.internalError("XCTRunnerDaemonSession class is unavailable")
        }
        let sharedSelector = NSSelectorFromString("sharedSession")
        guard sessionClass.responds(to: sharedSelector) else {
            throw RPCMethodError.internalError(
                "XCTRunnerDaemonSession does not respond to sharedSession"
            )
        }
        typealias SharedSession = @convention(c) (AnyClass, Selector) -> NSObject
        let sharedSession = unsafeBitCast(
            sessionClass.method(for: sharedSelector),
            to: SharedSession.self
        )
        let session = sharedSession(sessionClass, sharedSelector)

        let dispatchSelector = NSSelectorFromString("performDeviceEvent:completion:")
        guard session.responds(to: dispatchSelector) else {
            throw RPCMethodError.internalError(
                "XCTRunnerDaemonSession does not respond to performDeviceEvent:completion:"
            )
        }
        typealias DispatchEvent = @convention(c) (
            NSObject, Selector, NSObject, @escaping (Error?) -> Void
        ) -> Void
        let dispatchEvent = unsafeBitCast(
            session.method(for: dispatchSelector),
            to: DispatchEvent.self
        )

        return AsyncThrowingStream { continuation in
            dispatchEvent(session, dispatchSelector, event) { error in
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.yield(())
                    continuation.finish()
                }
            }
        }
    }
}
