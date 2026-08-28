import Foundation

/// One inbox per runner process. Constructing an inbox performs stale-request
/// recovery under the cross-process lock, so rebuilding it for every 512 KiB
/// read chunk turns a 25 MiB transfer into 50 unnecessary full-container scans.
@MainActor
private enum ShippingInboxProvider {
    static let result = Result { try ShippingInbox() }
}

@MainActor
func shippingInbox() throws -> ShippingInbox {
    try ShippingInboxProvider.result.get()
}

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

func shippingTerminalFields(_ terminal: ShippingImportTerminal) -> [String: JSONValue] {
    var value: [String: JSONValue] = [
        "requestId": .string(terminal.requestID.uuidString.lowercased()),
        "state": .string(terminal.state.rawValue),
    ]
    if let digest = terminal.sha256 {
        value["sha256"] = .string(digest)
    }
    return value
}

func shippingTerminalJSON(_ terminal: ShippingImportTerminal) -> JSONValue {
    .object(shippingTerminalFields(terminal))
}

/// One rendering of a status, shared by begin/status/active so the three can
/// never disagree about what a request is doing.
func shippingStatusFields(_ status: ShippingImportStatus) -> [String: JSONValue] {
    switch status {
    case .waiting:
        return ["state": .string("waiting")]
    case .ready(let manifest):
        return [
            "state": .string("ready"),
            "totalBytes": .int(manifest.byteCount),
            "sha256": .string(manifest.sha256),
        ]
    case .failed(let failure):
        return [
            "state": .string("failed"),
            "code": .string(failure.code),
            "message": .string(failure.message),
        ]
    case .acknowledged(let terminal), .cancelled(let terminal):
        return shippingTerminalFields(terminal)
    }
}
