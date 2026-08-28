import Foundation

@MainActor
struct ShippingImportStatusMethodHandler: RPCMethodHandler {
    static let methodName = "shipping.import.status"

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(ShippingImportRequestID.self, from: params)
        do {
            switch try ShippingInbox().status(requestID: shippingRequestID(request.requestId)) {
            case .waiting:
                return .object(["state": .string("waiting")])
            case .ready(let manifest):
                return .object([
                    "state": .string("ready"),
                    "totalBytes": .int(manifest.byteCount),
                    "sha256": .string(manifest.sha256),
                ])
            case .failed(let failure):
                return .object([
                    "state": .string("failed"),
                    "code": .string(failure.code),
                    "message": .string(failure.message),
                ])
            case .acknowledged(let terminal), .cancelled(let terminal):
                return shippingTerminalJSON(terminal)
            }
        } catch {
            throw shippingRPCError(error)
        }
    }
}
