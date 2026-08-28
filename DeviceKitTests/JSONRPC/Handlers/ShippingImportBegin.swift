import Foundation

@MainActor
struct ShippingImportBeginMethodHandler: RPCMethodHandler {
    static let methodName = "shipping.import.begin"

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(ShippingImportBeginRequest.self, from: params)
        do {
            let created = try ShippingInbox().begin(
                requestID: shippingRequestID(request.requestId),
                maxBytes: request.maxBytes
            )
            return .object([
                "requestId": .string(created.requestID.uuidString.lowercased()),
                "maxBytes": .int(created.maxBytes),
                "state": .string("waiting"),
            ])
        } catch {
            throw shippingRPCError(error)
        }
    }
}
