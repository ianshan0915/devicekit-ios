import FlyingFox
import Foundation

@MainActor
struct JSONRPCHTTPHandler: HTTPHandler {

    private let dispatcher: JSONRPCDispatcher

    init(dispatcher: JSONRPCDispatcher) {
        self.dispatcher = dispatcher
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let bodyData = try await request.bodyData
        // RPC bodies may contain clipboard text, screenshots or uploaded files.
        // Logging only the size keeps customer data out of on-device logs.
        NSLog("Received HTTP JSON-RPC request (\(bodyData.count) bytes)")

        let responseData = await dispatcher.dispatch(bodyData)

        NSLog("Sending HTTP JSON-RPC response (\(responseData.count) bytes)")

        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: responseData
        )
    }
}
