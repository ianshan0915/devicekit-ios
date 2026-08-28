import Foundation

/// Recovery entry point. A host that lost its request id — session crash, or the
/// phone carried to a different host — is otherwise locked out by
/// `another_request_active` until the 24-hour stale purge releases the slot, with
/// no way to name the request blocking it. This reports what is holding the slot
/// so it can be cancelled.
@MainActor
struct ShippingImportActiveMethodHandler: RPCMethodHandler {
    static let methodName = "shipping.import.active"

    func execute(params: JSONValue?) async throws -> JSONValue {
        do {
            let inbox = try ShippingInbox()
            let requests = try inbox.activeRequests().map { request -> JSONValue in
                // A request that reaches a terminal state between the scan and this
                // lookup is simply no longer active; report it as still waiting
                // rather than failing the whole recovery call.
                var value = shippingStatusFields(
                    (try? inbox.status(requestID: request.requestID)) ?? .waiting
                )
                value["requestId"] = .string(request.requestID.uuidString.lowercased())
                value["maxBytes"] = .int(request.maxBytes)
                return .object(value)
            }
            return .object(["requests": .array(requests)])
        } catch {
            throw shippingRPCError(error)
        }
    }
}
