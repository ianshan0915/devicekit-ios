import Foundation

@MainActor
struct ShippingImportCancelMethodHandler: RPCMethodHandler {
    static let methodName = "shipping.import.cancel"

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(ShippingImportRequestID.self, from: params)
        do {
            return shippingTerminalJSON(
                try shippingInbox().cancel(requestID: shippingRequestID(request.requestId))
            )
        } catch {
            throw shippingRPCError(error)
        }
    }
}
