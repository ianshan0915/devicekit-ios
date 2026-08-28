import Foundation

@MainActor
struct ShippingImportBeginMethodHandler: RPCMethodHandler {
    static let methodName = "shipping.import.begin"

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(ShippingImportBeginRequest.self, from: params)
        do {
            let inbox = try ShippingInbox()
            let created = try inbox.begin(
                requestID: shippingRequestID(request.requestId),
                maxBytes: request.maxBytes
            )
            // begin is idempotent. Replaying it for a request the extension has
            // already fulfilled must report the committed state — hardcoding
            // "waiting" told a reconnecting host a ready import was still pending.
            var value = shippingStatusFields(try inbox.status(requestID: created.requestID))
            value["requestId"] = .string(created.requestID.uuidString.lowercased())
            value["maxBytes"] = .int(created.maxBytes)
            return .object(value)
        } catch {
            throw shippingRPCError(error)
        }
    }
}
