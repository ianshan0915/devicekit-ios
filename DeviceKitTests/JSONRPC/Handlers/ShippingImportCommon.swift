import Foundation

struct ShippingImportRequestID: Decodable {
    let requestId: String
}

struct ShippingImportBeginRequest: Decodable {
    let requestId: String
    let maxBytes: Int
}

struct ShippingImportReadRequest: Decodable {
    let requestId: String
    let offset: Int
    let maxBytes: Int
}

struct ShippingImportAckRequest: Decodable {
    let requestId: String
    let sha256: String
}

func shippingRequestID(_ rawValue: String) throws -> UUID {
    guard let requestID = UUID(uuidString: rawValue),
          requestID.uuidString.caseInsensitiveCompare(rawValue) == .orderedSame else {
        throw RPCMethodError.operation(
            code: ShippingInboxError.invalidRequestID.diagnosticCode,
            message: ShippingInboxError.invalidRequestID.localizedDescription
        )
    }
    return requestID
}

func shippingRPCError(_ error: Error) -> RPCMethodError {
    if let rpcError = error as? RPCMethodError {
        return rpcError
    }
    if let inboxError = error as? ShippingInboxError {
        return .operation(code: inboxError.diagnosticCode, message: inboxError.localizedDescription)
    }
    return .internalError(error.localizedDescription)
}

func shippingTerminalJSON(_ terminal: ShippingImportTerminal) -> JSONValue {
    var value: [String: JSONValue] = [
        "requestId": .string(terminal.requestID.uuidString.lowercased()),
        "state": .string(terminal.state.rawValue),
    ]
    if let digest = terminal.sha256 {
        value["sha256"] = .string(digest)
    }
    return .object(value)
}
