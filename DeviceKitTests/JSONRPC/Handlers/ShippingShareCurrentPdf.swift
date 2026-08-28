import Foundation
import XCTest

private struct ShippingShareCurrentPDFRequest: Decodable {
    let requestId: String
    let timeoutSeconds: Double?
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
            "Safari's Share button is unavailable."
        case .missingExtension:
            "YJ Commerce is missing from the Share sheet."
        case .targetNotOffered:
            """
            The Share sheet opened but did not offer YJ Commerce — the phone may be \
            missing the shipping Share Extension, or this page is not a PDF.
            """
        case .attachmentRejected:
            "Safari did not provide a usable PDF shipping label."
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
            inbox = try ShippingInbox()
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

        guard let safari = foregroundSafari() else {
            throw actionError(.missingSafariPDF)
        }
        guard openShareSheet(in: safari) else {
            throw actionError(.missingShareAction)
        }

        guard let sharing = shareSheetContext(openedFrom: safari) else {
            throw actionError(.missingShareAction)
        }

        guard let target = visibleShareTarget(in: sharing)
                ?? revealShareTarget(in: sharing) else {
            // Safari was verified foreground and its Share sheet is open, so
            // `missingSafariPDF` ("open the label in Safari first") would tell the
            // operator to redo a step that already succeeded. A PDF hint narrows
            // this to a missing extension; without one the two causes — extension
            // absent, or the page is not a PDF — are genuinely indistinguishable
            // from here, and the error says so rather than guessing.
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

    private func foregroundSafari() -> XCUIApplication? {
        guard let foreground = RunningApp.getForegroundApp(),
              let bundleID = foreground.bundleID,
              Self.safariBundleIDs.contains(bundleID) else {
            return nil
        }
        return foreground
    }

    private func openShareSheet(in safari: XCUIApplication) -> Bool {
        if openVisibleShareAction(in: safari) {
            return true
        }

        // Safari hides its PDF toolbar after a short idle period and after a
        // relaunch. Tap the identified PDF accessibility element once to show
        // the controls, then re-query them. This remains element-driven; never
        // guess a screen coordinate.
        guard revealPDFControls(in: safari) else { return false }
        Thread.sleep(forTimeInterval: 0.25)
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

    private func revealShareTarget(in sharing: XCUIApplication) -> XCUIElement? {
        guard let row = applicationRow(in: sharing) else { return nil }
        for _ in 0..<Self.maximumApplicationRowSwipes {
            row.swipeLeft()
            Thread.sleep(forTimeInterval: 0.2)
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
        sharing.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "PDF")
        ).firstMatch.exists
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
