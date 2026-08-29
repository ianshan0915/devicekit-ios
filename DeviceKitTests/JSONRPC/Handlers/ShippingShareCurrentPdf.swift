import Foundation
import XCTest

private struct ShippingShareCurrentPDFRequest: Decodable {
    let requestId: String
    let timeoutSeconds: Double?
    let sourceBundleId: String?
}

private enum ShippingShareActionError: String, LocalizedError {
    case missingSafariPDF = "printable_pdf_not_in_safari"
    case missingShareAction = "share_action_not_found"
    case missingExtension = "share_target_not_found"
    case targetNotOffered = "share_target_not_offered"
    case attachmentRejected = "source_not_pdf"
    case timeout = "share_import_timeout"
    case cancelled = "share_import_cancelled"

    var errorDescription: String? {
        switch self {
        case .missingSafariPDF:
            "Open the printable shipping label in Safari first."
        case .missingShareAction:
            "The printable PDF Share action is unavailable."
        case .missingExtension:
            "YJ Commerce is missing from the Share sheet."
        case .targetNotOffered:
            """
            The Share sheet opened but did not offer YJ Commerce — the phone may be \
            missing the shipping Share Extension, or this page is not a PDF.
            """
        case .attachmentRejected:
            "The source app did not provide a usable PDF shipping label."
        case .timeout:
            "Saving the shipping label took too long."
        case .cancelled:
            "Saving the shipping label was cancelled."
        }
    }
}

@MainActor
struct ShippingShareCurrentPdfMethodHandler: RPCMethodHandler {
    static let methodName = "shipping.shareCurrentPdf"

    private static let safariBundleIDs = [
        "com.apple.mobilesafari",
        "com.apple.SafariViewService",
    ]
    private static let shareTargetLabels = ["YJ Commerce", "Save shipping label"]
    private static let maximumApplicationRowSwipes = 3

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(ShippingShareCurrentPDFRequest.self, from: params)
        let requestID = try shippingRequestID(request.requestId)
        let timeoutSeconds = min(max(request.timeoutSeconds ?? 15, 1), 30)
        let inbox: ShippingInbox
        do {
            inbox = try shippingInbox()
            switch try inbox.status(requestID: requestID) {
            case .ready(let manifest):
                return readyJSON(manifest)
            case .waiting:
                break
            case .failed(let failure):
                throw importFailureError(failure)
            case .acknowledged(let terminal):
                return shippingTerminalJSON(terminal)
            case .cancelled:
                throw actionError(.cancelled)
            }
        } catch {
            throw shippingRPCError(error)
        }

        let sourceBundleID = request.sourceBundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIsNonSafari = sourceBundleID.map {
            !$0.isEmpty && !Self.safariBundleIDs.contains($0)
        } ?? false
        let foregroundIsSafari = RunningApp.getForegroundApp()?.bundleID.map {
            Self.safariBundleIDs.contains($0)
        } ?? false

        let sharing: XCUIApplication
        // The established Safari path opens its own sheet below. Probing for a
        // pre-presented sheet first can never help when Safari is foreground,
        // and used to burn four seconds on the main actor every invocation.
        if !foregroundIsSafari,
           let presented = try await presentedPDFShareSheet(sourceBundleID: sourceBundleID) {
            // Vinted's in-app PDF viewer owns the Share button. The host opens
            // that one deterministic toolbar action, then this runner selects
            // the exact extension element. Keeping the Share-sheet operation
            // here avoids exporting unreliable system rectangles to the host.
            sharing = presented
        } else {
            // A caller that named Vinted (or another source app) is explicitly
            // asking us to use an already-presented in-app sheet. Falling back
            // to Safari here gives the operator instructions for an app they
            // never opened.
            if sourceIsNonSafari {
                throw actionError(.missingShareAction)
            }
            guard let safari = foregroundSafari() else {
                throw actionError(.missingSafariPDF)
            }
            guard try await openShareSheet(in: safari) else {
                throw actionError(.missingShareAction)
            }

            guard let opened = shareSheetContext(openedFrom: safari) else {
                throw actionError(.missingShareAction)
            }
            sharing = opened
        }

        let target: XCUIElement?
        if let visible = try await waitForVisibleShareTarget(in: sharing, timeout: 2) {
            target = visible
        } else {
            target = try await revealShareTarget(in: sharing)
        }
        guard let target else {
            // A source-app or Safari Share sheet is already open, so telling
            // the operator to reopen the label would be wrong. A PDF hint
            // narrows this to a missing extension; without one the two causes
            // remain genuinely indistinguishable.
            throw actionError(hasPDFHint(in: sharing) ? .missingExtension : .targetNotOffered)
        }
        guard target.isHittable else {
            throw actionError(.missingExtension)
        }

        // Tap the XCUIElement itself. Exported Share Sheet rectangles are wrong
        // on some current iOS versions and must never be converted to host-side
        // coordinates.
        target.tap()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            do {
                switch try inbox.status(requestID: requestID) {
                case .waiting:
                    break
                case .ready(let manifest):
                    return readyJSON(manifest)
                case .failed(let failure):
                    throw importFailureError(failure)
                case .acknowledged(let terminal):
                    return shippingTerminalJSON(terminal)
                case .cancelled:
                    throw actionError(.cancelled)
                }
            } catch let error as RPCMethodError {
                throw error
            } catch {
                throw shippingRPCError(error)
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw actionError(.timeout)
    }

    private func shareSheetContext(openedFrom safari: XCUIApplication) -> XCUIApplication? {
        let sharing = XCUIApplication(bundleIdentifier: "com.apple.SharingViewService")
        if sharing.wait(for: .runningForeground, timeout: 2)
            || sharing.cells.firstMatch.waitForExistence(timeout: 1) {
            return sharing
        }

        // iOS 15 presents the activity controller inside Safari's process
        // rather than a foreground SharingViewService application. The
        // presence of Share-sheet cells after the verified Share action is the
        // bounded compatibility signal; all later queries stay in that app.
        if safari.cells.firstMatch.waitForExistence(timeout: 2) {
            return safari
        }
        return nil
    }

    private func presentedPDFShareSheet(
        sourceBundleID: String?
    ) async throws -> XCUIApplication? {
        // The host captures the source bundle before opening an in-app Share
        // sheet. Query that exact hierarchy first: while the sheet is visible,
        // iOS may temporarily classify SpringBoard rather than the source app
        // as foreground.
        var bundleIDs: [String] = []
        if let sourceBundleID, !sourceBundleID.isEmpty {
            bundleIDs.append(sourceBundleID)
        }
        bundleIDs.append("com.apple.SharingViewService")
        // Backward compatibility for callers that predate sourceBundleId and
        // for iOS versions that do keep the source app foreground.
        if let foregroundBundleID = RunningApp.getForegroundApp()?.bundleID,
           foregroundBundleID != RunningApp.springboardBundleId {
            bundleIDs.append(foregroundBundleID)
        }

        var seen = Set<String>()
        let candidates = bundleIDs.compactMap { bundleID -> XCUIApplication? in
            guard seen.insert(bundleID).inserted,
                  !Self.safariBundleIDs.contains(bundleID),
                  bundleID != Bundle.main.bundleIdentifier else {
                return nil
            }
            return XCUIApplication(bundleIdentifier: bundleID)
        }

        // The attachment and application cells can take several seconds to
        // enter the XCUI hierarchy on older phones. Require both the PDF signal
        // and an activity row, so unrelated content containing the text "PDF"
        // cannot authorize sharing arbitrary content.
        let deadline = Date().addingTimeInterval(4)
        while true {
            for candidate in candidates where isPDFShareSheet(candidate) {
                return candidate
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            try await cooperativeSleep(min(0.2, remaining))
        }
        return nil
    }

    private func foregroundSafari() -> XCUIApplication? {
        guard let foreground = RunningApp.getForegroundApp(),
              let bundleID = foreground.bundleID,
              Self.safariBundleIDs.contains(bundleID) else {
            return nil
        }
        return foreground
    }

    private func openShareSheet(in safari: XCUIApplication) async throws -> Bool {
        if openVisibleShareAction(in: safari) {
            return true
        }

        // Safari hides its PDF toolbar after a short idle period and after a
        // relaunch. Tap the identified PDF accessibility element once to show
        // the controls, then re-query them. This remains element-driven; never
        // guess a screen coordinate.
        guard revealPDFControls(in: safari) else { return false }
        try await cooperativeSleep(0.25)
        return openVisibleShareAction(in: safari)
    }

    private func openVisibleShareAction(in safari: XCUIApplication) -> Bool {
        if let share = firstElement(
            in: safari.buttons,
            identifiers: ["ShareButton"],
            labels: ["Share", "Deel", "Partager", "Teilen"]
        ) {
            share.tap()
            return true
        }

        guard let more = firstElement(
            in: safari.buttons,
            identifiers: ["MoreMenuButton"],
            labels: ["More", "Meer", "Plus", "Mehr"]
        ) else {
            return false
        }
        more.tap()

        let share = firstElement(
            in: safari.buttons,
            identifiers: ["ShareButton"],
            labels: ["Share", "Deel", "Partager", "Teilen"],
            wait: 2
        )
        guard let share else { return false }
        share.tap()
        return true
    }

    private func revealPDFControls(in safari: XCUIApplication) -> Bool {
        let pdf = safari.otherElements.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "PDF")
        ).firstMatch
        guard pdf.exists, pdf.isHittable else { return false }
        pdf.tap()
        return true
    }

    private func visibleShareTarget(in sharing: XCUIApplication) -> XCUIElement? {
        for label in Self.shareTargetLabels {
            let predicate = NSPredicate(format: "label == %@", label)
            for query in [sharing.cells, sharing.buttons, sharing.staticTexts] {
                let element = query.matching(predicate).firstMatch
                if element.exists, element.isHittable {
                    return element
                }
            }
        }
        return nil
    }

    private func waitForVisibleShareTarget(
        in sharing: XCUIApplication,
        timeout: TimeInterval
    ) async throws -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let target = visibleShareTarget(in: sharing) {
                return target
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            try await cooperativeSleep(min(0.2, remaining))
        }
        return nil
    }

    private func revealShareTarget(
        in sharing: XCUIApplication
    ) async throws -> XCUIElement? {
        guard let row = applicationRow(in: sharing) else { return nil }
        for _ in 0..<Self.maximumApplicationRowSwipes {
            row.swipeLeft()
            try await cooperativeSleep(0.2)
            if let target = visibleShareTarget(in: sharing) {
                return target
            }
        }
        return nil
    }

    private func applicationRow(in sharing: XCUIApplication) -> XCUIElement? {
        for collection in sharing.collectionViews.allElementsBoundByIndex {
            let shareCells = collection.cells.matching(identifier: "shareCell")
            if shareCells.firstMatch.exists {
                return collection
            }
            let airDrop = collection.cells.matching(
                NSPredicate(format: "label == %@", "AirDrop")
            ).firstMatch
            if airDrop.exists {
                return collection
            }
        }
        return nil
    }

    private func hasPDFHint(in sharing: XCUIApplication) -> Bool {
        // Share-sheet attachment metadata is not consistently typed. On the
        // tested Vinted/iOS combination, "PDF Document · 20 KB" is an
        // XCUIElementTypeOther rather than a static text even though it has an
        // accessibility label. Limit the search to the two observed element
        // types; a descendants(.any) snapshot of Vinted's full hierarchy can
        // take seconds on older phones and defeat the bounded polling loop.
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "PDF")
        return [sharing.staticTexts, sharing.otherElements].contains { query in
            query.matching(predicate).firstMatch.exists
        }
    }

    private func isPDFShareSheet(_ sharing: XCUIApplication) -> Bool {
        guard hasPDFHint(in: sharing) else { return false }
        return sharing.cells.matching(identifier: "shareCell").firstMatch.exists
            || visibleShareTarget(in: sharing) != nil
    }

    private func cooperativeSleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func firstElement(
        in query: XCUIElementQuery,
        identifiers: [String],
        labels: [String],
        wait: TimeInterval = 0
    ) -> XCUIElement? {
        for identifier in identifiers {
            let element = query.matching(identifier: identifier).firstMatch
            if wait > 0 ? element.waitForExistence(timeout: wait) : element.exists {
                return element
            }
        }
        for label in labels {
            let element = query.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if wait > 0 ? element.waitForExistence(timeout: wait) : element.exists {
                return element
            }
        }
        return nil
    }

    private func readyJSON(_ manifest: ShippingImportManifest) -> JSONValue {
        .object([
            "state": .string("ready"),
            "totalBytes": .int(manifest.byteCount),
            "sha256": .string(manifest.sha256),
        ])
    }

    private func actionError(
        _ error: ShippingShareActionError
    ) -> RPCMethodError {
        .operation(code: error.rawValue, message: error.localizedDescription)
    }

    private func importFailureError(_ failure: ShippingImportFailure) -> RPCMethodError {
        if failure.code == ShippingInboxError.sourceTooLarge.diagnosticCode {
            return .operation(
                code: failure.code,
                message: ShippingInboxError.sourceTooLarge.localizedDescription
            )
        }
        return actionError(.attachmentRejected)
    }
}
