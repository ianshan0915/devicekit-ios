// Reads text from the systemwide iOS pasteboard for an explicit host-side
// "copy from device" action. The value is returned only in the JSON-RPC body;
// transport handlers log byte counts rather than request/response bodies so
// verification codes and customer text never enter device logs.
import UIKit
import XCTest

@MainActor
struct ClipboardMethodHandler: RPCMethodHandler {
    static let methodName = "device.clipboard"

    // Keep the JSON-RPC response bounded before JSON escaping/base64-free
    // transport overhead. This matches the host's Android clipboard limit.
    private static let maxBytes = 64 * 1024

    func execute(params: JSONValue?) async throws -> JSONValue {
        // Real devices hide the general pasteboard from an XCUITest runner
        // while another app (including SpringBoard) is foreground. Preserve
        // the tester's current app, briefly foreground this runner for the
        // explicit clipboard pull, then put the tester back where they were.
        // This also makes any iOS paste-access prompt visible to the tester.
        let foregroundBundleId = RunningApp.getForegroundApp()?.bundleID
        let runnerBundleId = Bundle.main.bundleIdentifier
        let shouldActivateRunner = runnerBundleId != nil && foregroundBundleId != runnerBundleId

        if shouldActivateRunner, let runnerBundleId {
            XCUIApplication(bundleIdentifier: runnerBundleId).activate()
        }
        defer {
            if shouldActivateRunner, let foregroundBundleId {
                if foregroundBundleId == RunningApp.springboardBundleId {
                    XCUIDevice.shared.press(.home)
                } else {
                    XCUIApplication(bundleIdentifier: foregroundBundleId).activate()
                }
            }
        }

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
