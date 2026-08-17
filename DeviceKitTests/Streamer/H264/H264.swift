import FlyingFox
import FlyingSocks
import Foundation
import os
import CoreImage
import CoreMedia
import H264Codec

struct ActionCaptureHintSnapshot: Sendable {
    let generation: UInt64
    let requestedAtNs: UInt64
}

/// Process-wide, bounded hint from a completed UI action to opt-in H.264
/// streams. The dispatcher and frame capture both run on MainActor, so this is
/// deliberately a coalescing generation counter rather than a queue: a burst
/// of controls can extend one capture window but can never accumulate work.
@MainActor
enum ActionCaptureHints {
    private static var generation: UInt64 = 0
    private static var requestedAtNs: UInt64 = 0

    private static let visibleActionMethods: Set<String> = [
        "device.io.tap",
        "device.io.gesture",
        "device.io.button",
        "device.io.text",
        "device.io.swipe",
        "device.io.longpress",
        "device.io.orientation.set",
        "device.apps.launch",
        "device.apps.terminate",
        "device.url",
    ]

    static func request(after method: String) {
        guard visibleActionMethods.contains(method) else { return }
        generation &+= 1
        requestedAtNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    static func snapshot() -> ActionCaptureHintSnapshot {
        ActionCaptureHintSnapshot(
            generation: generation,
            requestedAtNs: requestedAtNs
        )
    }
}

private enum H264Constants {
    static let defaultFPS: Int = 30
    static let maxFPS: Int = 60
    static let defaultBitrate: Int = 4_000_000
    static let minBitrate: Int = 100_000
    static let maxBitrate: Int = 10_000_000
    static let defaultQuality: Int = 60
    static let defaultScale: Int = 50
    static let minScale: Int = 10
    static let maxScale: Int = 100
}

struct H264HTTPStreamConfig: Sendable {
    let fps: Int
    let bitrate: Int
    let quality: Float
    let scale: Float
    let suppressDuplicates: Bool
    /// 0 = ordinary stream, 1 = rejected B04 behavior, 2 = guarded successor.
    let actionCaptureMode: Int
    let frameInterval: UInt64

    init(
        fps: Int,
        bitrate: Int,
        quality: Float,
        scale: Float,
        suppressDuplicates: Bool = true,
        actionCaptureMode: Int = 0
    ) {
        self.fps = fps
        self.bitrate = bitrate
        self.quality = quality
        self.scale = scale
        self.suppressDuplicates = suppressDuplicates
        self.actionCaptureMode = actionCaptureMode
        self.frameInterval = UInt64(1_000_000_000 / max(1, fps))
    }
}

@MainActor
struct H264HTTPHandler: HTTPHandler {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "devicekit-ios",
        category: "H264Stream"
    )

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let fps = request.queryInt(name: "fps", default: H264Constants.defaultFPS, min: 1, max: H264Constants.maxFPS)
        let bitrate = request.queryInt(name: "bitrate", default: H264Constants.defaultBitrate, min: H264Constants.minBitrate, max: H264Constants.maxBitrate)
        let quality = Float(request.queryInt(name: "quality", default: H264Constants.defaultQuality, min: 1, max: 100)) / 100.0
        let scalePercent = request.queryInt(name: "scale", default: H264Constants.defaultScale, min: H264Constants.minScale, max: H264Constants.maxScale)
        let scale = Float(scalePercent) / 100.0
        // S08 experiment knob: dup=0 disables duplicate-frame suppression so the
        // same canary build can reproduce the reviewed runner's behavior.
        let suppressDuplicates = request.queryInt(name: "dup", default: 1, min: 0, max: 1) != 0
        // Both experiments are intentionally default-off. Mode 1 retains the
        // rejected B04 path for exact A/B reproduction. Mode 2 adds bounded
        // work, adaptive backpressure, and a cooldown circuit breaker. Omitting
        // the query preserves the reviewed production path byte-for-byte.
        let actionCaptureMode = request.queryInt(name: "action_capture", default: 0, min: 0, max: 2)

        logger.info("Starting H264 stream: scale=\(scalePercent)% @ \(fps)fps, \(bitrate/1_000_000)Mbps, dup=\(suppressDuplicates ? "on" : "off"), actionCaptureMode=\(actionCaptureMode)")

        let config = H264HTTPStreamConfig(
            fps: fps,
            bitrate: bitrate,
            quality: quality,
            scale: scale,
            suppressDuplicates: suppressDuplicates,
            actionCaptureMode: actionCaptureMode
        )
        let stream = H264ByteStream(config: config)
        let bodySequence = HTTPBodySequence(from: stream)

        var headers: [HTTPHeader: String] = [:]
        headers[.contentType] = "video/h264"
        headers[HTTPHeader("Server")] = "DeviceKit-iOS"
        headers[HTTPHeader("Connection")] = "close"
        headers[HTTPHeader("Cache-Control")] = "no-cache, no-store, must-revalidate"

        return HTTPResponse(statusCode: .ok, headers: headers, body: bodySequence)
    }

}

struct H264ByteStream: AsyncBufferedSequence, Sendable {
    typealias Element = UInt8

    let config: H264HTTPStreamConfig

    func makeAsyncIterator() -> H264ByteIterator {
        H264ByteIterator(config: config)
    }
}

final class H264ByteIterator: AsyncBufferedIteratorProtocol, @unchecked Sendable {
    typealias Element = UInt8
    typealias Buffer = [UInt8]

    private let config: H264HTTPStreamConfig
    private let frameProducer: H264FrameProducer
    private var naluStream: AsyncStream<Data>?
    private var naluIterator: AsyncStream<Data>.Iterator?
    private var captureTask: Task<Void, Never>?
    private var isCancelled = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "devicekit-ios",
        category: "H264Iterator"
    )

    init(config: H264HTTPStreamConfig) {
        self.config = config
        self.frameProducer = H264FrameProducer(
            suppressDuplicates: config.suppressDuplicates,
            actionCaptureMode: config.actionCaptureMode
        )

        let stream = frameProducer.makeNALUnitStream()
        self.naluStream = stream
        self.naluIterator = stream.makeAsyncIterator()

        startCaptureLoop()
    }

    deinit {
        captureTask?.cancel()
        frameProducer.invalidateEncoder()
    }

    private func startCaptureLoop() {
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                do {
                    try await self.captureFrame()
                } catch {
                    self.logger.error("Capture error: \(error.localizedDescription)")
                    break
                }
            }
        }
    }

    @MainActor
    private func captureFrame() async throws {
        try await frameProducer.captureAndEncodeFrame(
            fps: config.fps,
            bitrate: config.bitrate,
            quality: config.quality,
            scale: config.scale,
            frameInterval: config.frameInterval
        )
    }

    func next() async throws -> UInt8? {
        guard !isCancelled, !Task.isCancelled else { return nil }
        let buffer = try await nextBuffer(suggested: 1)
        return buffer?.first
    }

    func nextBuffer(suggested count: Int) async throws -> [UInt8]? {
        guard !isCancelled, !Task.isCancelled else {
            return nil
        }

        guard let data = await naluIterator?.next() else {
            isCancelled = true
            return nil
        }

        return Array(data)
    }
}
