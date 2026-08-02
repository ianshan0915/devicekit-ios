import Darwin
import XCTest
import os

struct IOTapRequest: Codable {
    let x: Float
    let y: Float
    /// One preserves the existing wire behavior. Two asks XCTest to synthesize
    /// both taps atomically, which is required for iOS custom Double-Tap actions;
    /// two serialized JSON-RPC calls fall outside SpringBoard's recognition window.
    let count: Int?
    /// Experimental-only knobs used to compare one latency variable at a time
    /// on a single signed canary installation. They are removed from the final
    /// runner after a fixed production configuration is selected.
    let experimentalDurationMilliseconds: Int?
    let experimentalBackend: String?
}

@MainActor
struct IOTapMethodHandler: RPCMethodHandler {
    static let methodName = "device.io.tap"

    private enum ExperimentalBackend: String {
        case daemonFresh
        case daemonCached
        case deviceSynthesizer
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )

    func execute(params: JSONValue?) async throws -> JSONValue {
        let handlerStart = monotonicTime()
        let request = try decodeParams(IOTapRequest.self, from: params)

        let coordinateResolutionStart = monotonicTime()
        let point = StreamCoordinateSpace.point(
            x: CGFloat(request.x),
            y: CGFloat(request.y)
        )
        let coordinateResolutionDuration = elapsedSeconds(
            since: coordinateResolutionStart
        )

        let tapCount = request.count ?? 1
        guard tapCount == 1 || tapCount == 2 else {
            throw RPCMethodError.invalidParams("Tap count must be 1 or 2")
        }

        let durationMilliseconds = request.experimentalDurationMilliseconds ?? 100
        guard (1...200).contains(durationMilliseconds) else {
            throw RPCMethodError.invalidParams(
                "experimentalDurationMilliseconds must be between 1 and 200"
            )
        }
        let backendName = request.experimentalBackend ?? ExperimentalBackend.daemonFresh.rawValue
        guard let backend = ExperimentalBackend(rawValue: backendName) else {
            throw RPCMethodError.invalidParams(
                "experimentalBackend must be daemonFresh, daemonCached, or deviceSynthesizer"
            )
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

            let constructionStart = monotonicTime()
            let eventRecord = EventRecord(orientation: .portrait)
            _ = eventRecord.addPointerTouchEvent(
                at: point,
                touchUpAfter: nil,
                defaultDuration: Double(durationMilliseconds) / 1_000
            )
            let constructionDuration = elapsedSeconds(since: constructionStart)

            let proxyStart = monotonicTime()
            let cachedProxy: RunnerDaemonProxy?
            switch backend {
            case .daemonFresh:
                cachedProxy = RunnerDaemonProxy()
            case .daemonCached:
                cachedProxy = RunnerDaemonProxy.shared
            case .deviceSynthesizer:
                cachedProxy = nil
            }
            let proxyDuration = elapsedSeconds(since: proxyStart)

            let synthesisStart = monotonicTime()
            if let cachedProxy {
                try await cachedProxy.synthesize(eventRecord: eventRecord)
            } else {
                try await RunnerDaemonProxy.synthesizeWithDevice(
                    eventRecord: eventRecord
                )
            }
            let synthesisDuration = elapsedSeconds(since: synthesisStart)
            let duration = Date().timeIntervalSince(start)
            logger.info("Tapping took \(duration)")
            let totalDuration = elapsedSeconds(since: handlerStart)
            return .object([
                "success": .bool(true),
                "experimental": .object([
                    "durationMilliseconds": .int(durationMilliseconds),
                    "backend": .string(backend.rawValue),
                ]),
                "timings": .object([
                    "coordinateResolutionSeconds": .double(
                        coordinateResolutionDuration
                    ),
                    "eventConstructionSeconds": .double(constructionDuration),
                    "proxyAcquisitionSeconds": .double(proxyDuration),
                    "synthesisSeconds": .double(synthesisDuration),
                    "handlerSeconds": .double(totalDuration),
                ]),
            ])
        } catch {
            logger.error("Error tapping: \(error)")
            throw RPCMethodError.internalError(
                "Error tapping point: \(error.localizedDescription)"
            )
        }
    }
}

private func monotonicTime() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}

private func elapsedSeconds(since start: UInt64) -> Double {
    Double(monotonicTime() - start) / 1_000_000_000
}
