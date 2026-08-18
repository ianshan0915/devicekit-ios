import Foundation

@MainActor
class RunnerDaemonProxy {
    private let session: NSObject
    private let proxy: NSObject

    init() {
        let clazz: AnyClass = NSClassFromString("XCTRunnerDaemonSession")!
        let selector = NSSelectorFromString("sharedSession")
        let imp = clazz.method(for: selector)
        typealias Method = @convention(c) (AnyClass, Selector) -> NSObject
        let method = unsafeBitCast(imp, to: Method.self)
        let sessionInstance = method(clazz, selector)
        session = sessionInstance

        proxy =
            sessionInstance
            .perform(NSSelectorFromString("daemonProxy"))
            .takeUnretainedValue() as! NSObject
    }

    /// Dispatches one hardware-button event through the runner session's
    /// asynchronous API. Unlike XCUIDevice.press, awaiting this completion
    /// yields the MainActor, allowing the unchanged-rate H.264 capture loop to
    /// run while testmanagerd performs the button action.
    func performDeviceEvent(page: UInt, usage: UInt, duration: TimeInterval) async throws {
        guard let eventClass = NSClassFromString("XCDeviceEvent") else {
            throw NSError(
                domain: "DeviceKit.RunnerDaemonProxy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "XCDeviceEvent is unavailable"]
            )
        }

        let makeSelector = NSSelectorFromString("deviceEventWithPage:usage:duration:")
        guard eventClass.responds(to: makeSelector) else {
            throw NSError(
                domain: "DeviceKit.RunnerDaemonProxy",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "XCDeviceEvent constructor is unavailable"]
            )
        }
        let makeIMP = eventClass.method(for: makeSelector)
        typealias MakeMethod =
            @convention(c) (AnyClass, Selector, UInt, UInt, TimeInterval) -> NSObject
        let makeEvent = unsafeBitCast(makeIMP, to: MakeMethod.self)
        let event = makeEvent(eventClass, makeSelector, page, usage, duration)

        let performSelector = NSSelectorFromString("performDeviceEvent:completion:")
        guard session.responds(to: performSelector) else {
            throw NSError(
                domain: "DeviceKit.RunnerDaemonProxy",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "runner device-event API is unavailable"]
            )
        }
        let performIMP = session.method(for: performSelector)
        typealias PerformMethod =
            @convention(c) (
                NSObject, Selector, NSObject, @escaping (Error?) -> Void
            ) -> Void
        let performEvent = unsafeBitCast(performIMP, to: PerformMethod.self)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            performEvent(session, performSelector, event) { error in
                if let error = error {
                    continuation.resume(with: .failure(error))
                } else {
                    continuation.resume(with: .success(()))
                }
            }
        }
    }

    func send(string: String, typingFrequency: Int = 10) async throws {
        let selector = NSSelectorFromString(
            "_XCT_sendString:maximumFrequency:completion:"
        )
        let imp = proxy.method(for: selector)
        typealias Method =
            @convention(c) (
                NSObject, Selector, NSString, Int, @escaping (Error?) -> Void
            ) -> Void
        let method = unsafeBitCast(imp, to: Method.self)
        return try await withCheckedThrowingContinuation { continuation in
            method(
                proxy,
                selector,
                string as NSString,
                typingFrequency,
                { error in
                    if let error = error {
                        continuation.resume(with: .failure(error))
                    } else {
                        continuation.resume(with: .success(()))
                    }
                }
            )
        }
    }

    func synthesize(eventRecord: EventRecord) async throws {
        let selector = NSSelectorFromString("_XCT_synthesizeEvent:completion:")
        let imp = proxy.method(for: selector)
        typealias Method =
            @convention(c) (
                NSObject, Selector, NSObject, @escaping (Error?) -> Void
            ) -> Void
        let method = unsafeBitCast(imp, to: Method.self)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            method(
                proxy,
                selector,
                eventRecord.eventRecord,
                { error in
                    if let error = error {
                        continuation.resume(with: .failure(error))
                    } else {
                        continuation.resume(with: .success(()))
                    }
                }
            )
        }
    }

}
