import FlyingFox
import FlyingSocks
import Foundation
import os
import CoreImage
import CoreMedia
import H264Codec

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
    static let defaultStaticFPS: Int = 5
    static let defaultAdaptiveAfterMS: Int = 2_000
    static let minAdaptiveAfterMS: Int = 500
    static let maxAdaptiveAfterMS: Int = 60_000
}

struct H264HTTPStreamConfig: Sendable {
    let fps: Int
    let bitrate: Int
    let quality: Float
    let scale: Float
    let suppressDuplicates: Bool
    let adaptiveCapture: Bool
    let staticFPS: Int
    let adaptiveAfterMS: Int
    let frameInterval: UInt64
    let staticFrameInterval: UInt64

    init(
        fps: Int,
        bitrate: Int,
        quality: Float,
        scale: Float,
        suppressDuplicates: Bool = true,
        adaptiveCapture: Bool = true,
        staticFPS: Int = 5,
        adaptiveAfterMS: Int = 2_000
    ) {
        self.fps = fps
        self.bitrate = bitrate
        self.quality = quality
        self.scale = scale
        self.suppressDuplicates = suppressDuplicates
        self.adaptiveCapture = adaptiveCapture && suppressDuplicates
        self.staticFPS = max(1, min(fps, staticFPS))
        self.adaptiveAfterMS = adaptiveAfterMS
        self.frameInterval = UInt64(1_000_000_000 / max(1, fps))
        self.staticFrameInterval = UInt64(1_000_000_000 / self.staticFPS)
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
        // Unlike duplicate suppression, adaptive capture reduces the screenshot
        // XPC work performed on the phone. A static screen backs off to 5 fps by
        // default; input wakes the loop before the next static capture deadline.
        let adaptiveCapture = request.queryInt(name: "adaptive", default: 1, min: 0, max: 1) != 0
        let staticFPS = min(
            fps,
            request.queryInt(name: "staticfps", default: H264Constants.defaultStaticFPS, min: 1, max: H264Constants.maxFPS)
        )
        let adaptiveAfterMS = request.queryInt(
            name: "adaptiveafterms",
            default: H264Constants.defaultAdaptiveAfterMS,
            min: H264Constants.minAdaptiveAfterMS,
            max: H264Constants.maxAdaptiveAfterMS
        )

        logger.info("Starting H264 stream: scale=\(scalePercent)% @ \(fps)fps, \(bitrate/1_000_000)Mbps, dup=\(suppressDuplicates ? "on" : "off"), adaptive=\(adaptiveCapture && suppressDuplicates ? "on" : "off"), staticfps=\(staticFPS), adaptiveafterms=\(adaptiveAfterMS)")

        let config = H264HTTPStreamConfig(
            fps: fps,
            bitrate: bitrate,
            quality: quality,
            scale: scale,
            suppressDuplicates: suppressDuplicates,
            adaptiveCapture: adaptiveCapture,
            staticFPS: staticFPS,
            adaptiveAfterMS: adaptiveAfterMS
        )
        let stream = H264ByteStream(config: config)
        let bodySequence = HTTPBodySequence(from: stream)

        var headers: [HTTPHeader: String] = [:]
        headers[.contentType] = "video/h264"
        headers[HTTPHeader("Server")] = "DeviceKit-iOS"
        headers[HTTPHeader("Connection")] = "close"
        headers[HTTPHeader("Cache-Control")] = "no-cache, no-store, must-revalidate"
        headers[HTTPHeader("X-DeviceKit-Adaptive-Capture")] = config.adaptiveCapture ? "on" : "off"
        headers[HTTPHeader("X-DeviceKit-Static-FPS")] = String(config.staticFPS)
        headers[HTTPHeader("X-DeviceKit-Adaptive-After-MS")] = String(config.adaptiveAfterMS)

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
            adaptiveCapture: config.adaptiveCapture,
            staticFrameInterval: config.staticFrameInterval,
            adaptiveAfterMS: config.adaptiveAfterMS
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
