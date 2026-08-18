import FlyingFox
import Foundation

/// Thread-safe handoff between the screenshot producer and the opt-in M06 RPC
/// timing path. Only instrumented `/h264?m06_timing=1` streams update it.
/// Ordinary streams and RPCs pay no lock or response-payload cost.
final class M06ControlTimingState: @unchecked Sendable {
    static let shared = M06ControlTimingState()

    struct RequestArrival: Sendable {
        let receivedAtNs: UInt64
        let screenshotActiveAtArrival: Bool
        let screenshotAgeAtArrivalNs: UInt64?
        let screenshotSequenceAtArrival: UInt64
        let lastScreenshotDurationNs: UInt64?
        let lastScreenshotFinishedAgoNs: UInt64?

        func responseTiming(
            mainActorStartedAtNs: UInt64,
            handlerCompletedAtNs: UInt64
        ) -> JSONValue {
            func milliseconds(_ value: UInt64) -> JSONValue {
                .double(Double(value) / 1_000_000.0)
            }

            var fields: [String: JSONValue] = [
                "schemaVersion": .int(1),
                "mainActorWaitMs": milliseconds(
                    mainActorStartedAtNs >= receivedAtNs
                        ? mainActorStartedAtNs - receivedAtNs
                        : 0
                ),
                "handlerMs": milliseconds(
                    handlerCompletedAtNs >= mainActorStartedAtNs
                        ? handlerCompletedAtNs - mainActorStartedAtNs
                        : 0
                ),
                "screenshotActiveAtArrival": .bool(screenshotActiveAtArrival),
                "screenshotSequenceAtArrival": .int(Int(clamping: screenshotSequenceAtArrival))
            ]
            if let screenshotAgeAtArrivalNs {
                fields["screenshotAgeAtArrivalMs"] = milliseconds(screenshotAgeAtArrivalNs)
            }
            if let lastScreenshotDurationNs {
                fields["lastScreenshotDurationMs"] = milliseconds(lastScreenshotDurationNs)
            }
            if let lastScreenshotFinishedAgoNs {
                fields["lastScreenshotFinishedAgoMs"] = milliseconds(lastScreenshotFinishedAgoNs)
            }
            return .object(fields)
        }
    }

    private let lock = NSLock()
    private var screenshotStartedAtNs: UInt64?
    private var screenshotSequence: UInt64 = 0
    private var lastScreenshotDurationNs: UInt64?
    private var lastScreenshotFinishedAtNs: UInt64?

    private init() {}

    func screenshotStarted(at now: UInt64) {
        lock.lock()
        screenshotSequence &+= 1
        screenshotStartedAtNs = now
        lock.unlock()
    }

    func screenshotFinished(at now: UInt64) {
        lock.lock()
        if let started = screenshotStartedAtNs, now >= started {
            lastScreenshotDurationNs = now - started
        }
        screenshotStartedAtNs = nil
        lastScreenshotFinishedAtNs = now
        lock.unlock()
    }

    func requestArrived(at now: UInt64) -> RequestArrival {
        lock.lock()
        let started = screenshotStartedAtNs
        let finished = lastScreenshotFinishedAtNs
        let arrival = RequestArrival(
            receivedAtNs: now,
            screenshotActiveAtArrival: started != nil,
            screenshotAgeAtArrivalNs: started.map { now >= $0 ? now - $0 : 0 },
            screenshotSequenceAtArrival: screenshotSequence,
            lastScreenshotDurationNs: lastScreenshotDurationNs,
            lastScreenshotFinishedAgoNs: finished.map { now >= $0 ? now - $0 : 0 }
        )
        lock.unlock()
        return arrival
    }
}

struct JSONRPCHTTPHandler: HTTPHandler, @unchecked Sendable {

    private let dispatcher: JSONRPCDispatcher

    @MainActor
    init(dispatcher: JSONRPCDispatcher) {
        self.dispatcher = dispatcher
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let timingRequested = request.queryInt(
            name: "m06_timing", default: 0, min: 0, max: 1
        ) == 1
        guard timingRequested else {
            // Preserve the reviewed behavior exactly: ordinary requests hop to
            // the main actor before reading their body or dispatching.
            return try await handleOrdinaryRequest(request)
        }

        let bodyData = try await request.bodyData
        logReceived(bodyData)
        let arrival = timingRequested
            ? M06ControlTimingState.shared.requestArrived(
                at: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            )
            : nil

        let responseData = await dispatcher.dispatch(
            bodyData,
            m06RequestArrival: arrival
        )

        return makeResponse(responseData)
    }

    @MainActor
    private func handleOrdinaryRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let bodyData = try await request.bodyData
        logReceived(bodyData)
        let responseData = await dispatcher.dispatch(bodyData)
        return makeResponse(responseData)
    }

    private func logReceived(_ bodyData: Data) {
        // RPC bodies may contain clipboard text, screenshots or uploaded files.
        // Logging only the size keeps customer data out of on-device logs.
        NSLog("Received HTTP JSON-RPC request (\(bodyData.count) bytes)")
    }

    private func makeResponse(_ responseData: Data) -> HTTPResponse {
        NSLog("Sending HTTP JSON-RPC response (\(responseData.count) bytes)")

        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: responseData
        )
    }
}
