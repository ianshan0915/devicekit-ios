import Foundation

@MainActor
struct ShippingImportAckMethodHandler: RPCMethodHandler {
    static let methodName = "shipping.import.ack"

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(ShippingImportAckRequest.self, from: params)
        do {
            return shippingTerminalJSON(
                try shippingInbox().acknowledge(
                    requestID: shippingRequestID(request.requestId),
                    sha256: request.sha256
                )
            )
        } catch {
            throw shippingRPCError(error)
        }
    }
}
