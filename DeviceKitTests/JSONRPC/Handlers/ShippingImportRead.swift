import Foundation

@MainActor
struct ShippingImportReadMethodHandler: RPCMethodHandler {
    static let methodName = "shipping.import.read"

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(ShippingImportReadRequest.self, from: params)
        do {
            let chunk = try ShippingInbox().read(
                requestID: shippingRequestID(request.requestId),
                offset: request.offset,
                maxBytes: request.maxBytes
            )
            return .object([
                "offset": .int(chunk.offset),
                "totalBytes": .int(chunk.totalBytes),
                "sha256": .string(chunk.sha256),
                "eof": .bool(chunk.eof),
                "dataBase64": .string(chunk.data.base64EncodedString()),
            ])
        } catch {
            throw shippingRPCError(error)
        }
    }
}
