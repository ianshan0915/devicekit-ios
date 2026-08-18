import os

private enum Constants {
    static let defaultSwipeDuration = 0.1
}

struct IOSwipeRequest: Decodable {
    let x1: Int
    let y1: Int
    let x2: Int
    let y2: Int
}

@MainActor
struct IOSwipeMethodHandler: RPCMethodHandler {
    static let methodName = "device.io.swipe"

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(IOSwipeRequest.self, from: params)

        do {
            let start = Date()
            try await swipePrivateAPI(
                start: StreamCoordinateSpace.point(
                    x: CGFloat(request.x1),
                    y: CGFloat(request.y1)
                ),
                end: StreamCoordinateSpace.point(
                    x: CGFloat(request.x2),
                    y: CGFloat(request.y2)
                ),
                duration: Constants.defaultSwipeDuration
            )
            let duration = Date().timeIntervalSince(start)

            return .object([
                "success": .bool(true),
                "durationSeconds": .double(duration),
            ])
        } catch {
            logger.error("Error performing swipe: \(error)")
            throw RPCMethodError.internalError("Error performing swipe: \(error.localizedDescription)")
        }
    }

    func swipePrivateAPI(start: CGPoint, end: CGPoint, duration: Double) async throws {
        logger.info("Swipe (v2) from \(start.debugDescription) to \(end.debugDescription) with duration \(duration)")

        let eventRecord = EventRecord(orientation: .portrait)
        _ = eventRecord.addSwipeEvent(start: start, end: end, duration: duration)

        try await RunnerDaemonProxy().synthesize(eventRecord: eventRecord)
    }
}
