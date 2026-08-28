import Foundation

@MainActor
struct ShippingImportStatusMethodHandler: RPCMethodHandler {
    static let methodName = "shipping.import.status"

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(ShippingImportRequestID.self, from: params)
        do {
            return .object(
                shippingStatusFields(
                    try ShippingInbox().status(requestID: shippingRequestID(request.requestId))
                )
            )
        } catch {
            throw shippingRPCError(error)
        }
    }
}
