import XCTest
import os

struct IOTapRequest: Codable {
    let x: Float
    let y: Float
    /// One preserves the existing wire behavior. Two asks XCTest to synthesize
    /// both taps atomically, which is required for iOS custom Double-Tap actions;
    /// two serialized JSON-RPC calls fall outside SpringBoard's recognition window.
    let count: Int?
}

@MainActor
struct IOTapMethodHandler: RPCMethodHandler {
    static let methodName = "device.io.tap"

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(IOTapRequest.self, from: params)

        let point = StreamCoordinateSpace.point(
            x: CGFloat(request.x),
            y: CGFloat(request.y)
        )

        let tapCount = request.count ?? 1
        guard tapCount == 1 || tapCount == 2 else {
            throw RPCMethodError.invalidParams("Tap count must be 1 or 2")
        }

        do {
            let start = Date()
            if tapCount == 2 {
                // XCUICoordinate.doubleTap() creates one synthesized XCTest event.
                // Building this from two DeviceKit requests is not equivalent: the
                // First request completion delays the second past the event gate.
                let springboard = XCUIApplication(
                    bundleIdentifier: "com.apple.springboard"
                )
                let (width, height) = OrientationGeometry.physicalScreenSize()
                let normalized = CGVector(
                    dx: point.x / CGFloat(width),
                    dy: point.y / CGFloat(height)
                )
                springboard
                    .coordinate(withNormalizedOffset: normalized)
                    .doubleTap()
                let duration = Date().timeIntervalSince(start)
                logger.info("Atomic double tap took \(duration)")
                return .object([
                    "success": .bool(true),
                    "count": .int(2),
                    "durationSeconds": .double(duration),
                ])
            }

            let eventRecord = EventRecord(orientation: .portrait)
            _ = eventRecord.addPointerTouchEvent(
                at: point,
                touchUpAfter: EventRecord.remoteTapDuration
            )
            try await RunnerDaemonProxy().synthesize(eventRecord: eventRecord)
            let duration = Date().timeIntervalSince(start)
            logger.info("Tapping took \(duration)")
            return .object([
                "success": .bool(true),
                "durationSeconds": .double(duration),
            ])
        } catch {
            logger.error("Error tapping: \(error)")
            throw RPCMethodError.internalError(
                "Error tapping point: \(error.localizedDescription)"
            )
        }
    }
}
