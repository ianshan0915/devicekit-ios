// Reads text from the systemwide iOS pasteboard for an explicit host-side
// "copy from device" action. The value is returned only in the JSON-RPC body;
// transport handlers log byte counts rather than request/response bodies so
// verification codes and customer text never enter device logs.
import UIKit

@MainActor
struct ClipboardMethodHandler: RPCMethodHandler {
    static let methodName = "device.clipboard"

    // Keep the JSON-RPC response bounded before JSON escaping/base64-free
    // transport overhead. This matches the host's Android clipboard limit.
    private static let maxBytes = 64 * 1024

    func execute(params: JSONValue?) async throws -> JSONValue {
        let pasteboard = UIPasteboard.general
        // Apple's type probe does not fetch content, so an empty/non-text
        // pasteboard avoids raising an unnecessary paste-access prompt.
        guard pasteboard.hasStrings, let text = pasteboard.string else {
            return .object(["available": .bool(false)])
        }

        let bytes = text.utf8.count
        if bytes > Self.maxBytes {
            return .object([
                "available": .bool(true),
                "tooLarge": .bool(true),
                "bytes": .int(bytes)
            ])
        }
        return .object([
            "available": .bool(true),
            "tooLarge": .bool(false),
            "bytes": .int(bytes),
            "text": .string(text)
        ])
    }
}
