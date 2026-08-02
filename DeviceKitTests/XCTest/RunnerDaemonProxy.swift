import Foundation
import XCTest

@MainActor
class RunnerDaemonProxy {
    static let shared = RunnerDaemonProxy()

    private let proxy: NSObject

    init() {
        let clazz: AnyClass = NSClassFromString("XCTRunnerDaemonSession")!
        let selector = NSSelectorFromString("sharedSession")
        let imp = clazz.method(for: selector)
        typealias Method = @convention(c) (AnyClass, Selector) -> NSObject
        let method = unsafeBitCast(imp, to: Method.self)
        let session = method(clazz, selector)

        proxy =
            session
            .perform(NSSelectorFromString("daemonProxy"))
            .takeUnretainedValue() as! NSObject
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

    /// Current WebDriverAgent uses XCUIDevice's event synthesizer instead of
    /// calling the runner-daemon proxy directly. Keep this as an experimental
    /// alternative until canary measurements establish whether it is faster
    /// and equally reliable on our supported iOS versions.
    static func synthesizeWithDevice(
        eventRecord: EventRecord
    ) async throws {
        let device = XCUIDevice.shared as NSObject
        let eventSynthesizerSelector = NSSelectorFromString("eventSynthesizer")
        guard device.responds(to: eventSynthesizerSelector),
              let synthesizer = device
                .perform(eventSynthesizerSelector)?
                .takeUnretainedValue() as? NSObject else {
            throw RPCMethodError.internalError(
                "XCUIDevice event synthesizer is unavailable"
            )
        }

        let selector = NSSelectorFromString("synthesizeEvent:completion:")
        guard synthesizer.responds(to: selector) else {
            throw RPCMethodError.internalError(
                "XCUIDevice event synthesizer cannot synthesize events"
            )
        }
        let imp = synthesizer.method(for: selector)
        typealias Method = @convention(c) (
            NSObject,
            Selector,
            NSObject,
            @escaping (Bool, Error?) -> Void
        ) -> Void
        let method = unsafeBitCast(imp, to: Method.self)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            method(
                synthesizer,
                selector,
                eventRecord.eventRecord,
                { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
}
