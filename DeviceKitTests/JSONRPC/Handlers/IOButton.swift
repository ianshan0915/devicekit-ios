import os

struct IOButtonRequest : Codable {
    enum Button: String, Codable {
        case home
        case lock
        case volumeUp
        case volumeDown
    }

    let button: Button
    let mode: Mode?

    enum Mode: String, Codable {
        case inflightCapture = "inflight-capture"
    }
}

@MainActor
struct IOButtonMethodHandler: RPCMethodHandler {
    static let methodName = "device.io.button"

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(IOButtonRequest.self, from: params)

        let start = Date()

        logger.info("[Start] Tapping on button: \(request.button.rawValue)")
        switch request.button {
        case .home:
            if request.mode == .inflightCapture {
                // Consumer page / Menu usage is the same Home event exercised
                // by XCUIDevice.press(.home). The 5 ms duration was verified by
                // the earlier device-event experiment; this path changes only
                // how we await it so normal capture can continue in flight.
                try await RunnerDaemonProxy().performDeviceEvent(
                    page: 0x0c,
                    usage: 0x40,
                    duration: 0.005
                )
            } else {
                XCUIDevice.shared.press(.home)
            }
        case .lock:
            guard request.mode == nil else {
                throw RPCMethodError.invalidParams("mode is supported only for Home")
            }
            XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        case .volumeUp:
            guard request.mode == nil else {
                throw RPCMethodError.invalidParams("mode is supported only for Home")
            }
            #if targetEnvironment(simulator)
            logger.warning("volumeUp button is not available on the Simulator")
            #else
            XCUIDevice.shared.press(.volumeUp)
            #endif
        case .volumeDown:
            guard request.mode == nil else {
                throw RPCMethodError.invalidParams("mode is supported only for Home")
            }
            #if targetEnvironment(simulator)
            logger.warning("volumeDown button is not available on the Simulator")
            #else
            XCUIDevice.shared.press(.volumeDown)
            #endif
        }
        logger.info("[Done] Tapping on button: \(request.button.rawValue)")

        let duration = Date().timeIntervalSince(start)
        let path = request.mode?.rawValue ?? "compat"
        logger.info("Button Tap duration took \(duration), path: \(path)")
        return .object(["success": .bool(true)])
    }
}

