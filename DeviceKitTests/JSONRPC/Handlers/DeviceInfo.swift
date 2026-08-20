import os

@MainActor
struct DeviceInfoMethodHandler: RPCMethodHandler {
    static let methodName = "device.info"

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )

    func execute(params: JSONValue?) async throws -> JSONValue {

        let start = Date()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let frame = springboard.frame
        let scale = Int(UIScreen.main.scale)
        let width = Int(frame.width)
        let height = Int(frame.height)

        let duration = Date().timeIntervalSince(start)
        logger.info("Device info took \(duration), screen: \(width)x\(height)@\(scale)x")

        let screenSize: JSONValue = .object([
            "width": .double(Double(width)),
            "height": .double(Double(height))
        ])
        return .object([
            "screenSize": screenSize,
            "scale": .double(Double(scale)),
            // Host bridges use this explicit capability before sending count=2.
            // Older runners ignore unknown request fields and would otherwise turn
            // an atomic double tap into a dangerous single tap.
            "capabilities": .array([
                .string("io.tap.count.2"),
                .string("device.clipboard.read"),
                // S08 experimental build marker: identifies a canary runner with
                // duplicate-frame suppression so device.info can confirm what a
                // phone actually carries (the prepare script warns experimental
                // runners must advertise their own capability).
                .string("io.devicefarm.dupframe.suppress"),
                .string("io.devicefarm.control-timing-v1"),
                .string("io.devicefarm.swipe-duration-v2"),
                .string("io.devicefarm.tap-duration-v1"),
                .string("io.devicefarm.gesture-duration-v1"),
                .string("io.devicefarm.h264-trailing-aud-v1")
            ]),
            // R2: the exact runner commit this build was compiled from, injected
            // into the built bundle's Info.plist by prepare-ios-devicekit.sh.
            // Lets Mac/Windows comparisons prove both sides ran the same runner
            // instead of guessing from capabilities.
            "commitSHA": .string(
                (Bundle.main.object(forInfoDictionaryKey: "DeviceKitCommitSHA") as? String)
                    ?? "unknown"
            )
        ])
    }
}
