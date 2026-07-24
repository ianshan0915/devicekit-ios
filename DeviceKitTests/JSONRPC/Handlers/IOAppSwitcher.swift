import Foundation
import XCTest
import os

struct IOAppSwitcherRequest: Codable {
    /// Kept for wire compatibility with the first implementation. XCTest now represents
    /// the double-click atomically on XCDeviceEvent, so no host-selected gap is needed.
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
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )

    func execute(params: JSONValue?) async throws -> JSONValue {
        _ = try decodeParams(IOAppSwitcherRequest.self, from: params)

        logger.info("[Start] app switcher: atomic double home click")
        let start = Date()
        try dispatchHomeDoubleClick()
        let duration = Date().timeIntervalSince(start)
        logger.info("[Done] app switcher took \(duration)")

        return .object(["success": .bool(true), "clicks": .int(2)])
    }

    /// Represents both clicks on one XCDeviceEvent. Dispatching two separate events via
    /// XCUIDevice serializes them outside SpringBoard's double-click window, while trying
    /// to enqueue the second asynchronously is rejected by XCTest's one-gesture gate.
    private func dispatchHomeDoubleClick() throws {
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

        let setClicksSelector = NSSelectorFromString("setClicks:")
        guard event.responds(to: setClicksSelector) else {
            throw RPCMethodError.internalError(
                "XCDeviceEvent does not respond to setClicks:"
            )
        }
        typealias SetClicks = @convention(c) (NSObject, Selector, UInt64) -> Void
        let setClicks = unsafeBitCast(
            event.method(for: setClicksSelector),
            to: SetClicks.self
        )
        setClicks(event, setClicksSelector, 2)

        let device = XCUIDevice.shared as NSObject
        let dispatchSelector = NSSelectorFromString("performDeviceEvent:error:")
        guard device.responds(to: dispatchSelector) else {
            throw RPCMethodError.internalError(
                "XCUIDevice does not respond to performDeviceEvent:error:"
            )
        }
        typealias DispatchEvent = @convention(c) (
            NSObject, Selector, NSObject, UnsafeMutablePointer<NSError?>?
        ) -> Bool
        let dispatchEvent = unsafeBitCast(
            device.method(for: dispatchSelector),
            to: DispatchEvent.self
        )
        var dispatchError: NSError?
        guard dispatchEvent(device, dispatchSelector, event, &dispatchError) else {
            throw RPCMethodError.internalError(
                dispatchError?.localizedDescription ?? "Failed to dispatch home double-click"
            )
        }
    }
}
