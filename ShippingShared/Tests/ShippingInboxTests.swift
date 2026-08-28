import Foundation
import XCTest
@testable import ShippingShared

final class ShippingInboxTests: XCTestCase {
    private var root: URL!
    private var inbox: ShippingInbox!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shipping-inbox-tests-\(UUID().uuidString)", isDirectory: true)
        inbox = try ShippingInbox(rootURL: root, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testManifestIsCommittedAfterByteIdenticalPDF() throws {
        let requestID = UUID()
        let bytes = Data("%PDF-1.4\nsynthetic shipping label\n%%EOF\n".utf8)
        let source = root.appendingPathComponent("fixture.pdf")
        try bytes.write(to: source)

        try inbox.begin(requestID: requestID, maxBytes: 1024)
        XCTAssertEqual(try inbox.status(requestID: requestID), .waiting)
        let manifest = try inbox.importPDF(from: source)

        XCTAssertEqual(manifest.byteCount, bytes.count)
        guard case .ready(let saved) = try inbox.status(requestID: requestID) else {
            return XCTFail("Expected a committed manifest")
        }
        XCTAssertEqual(saved, manifest)

        let chunk = try inbox.read(requestID: requestID, offset: 0, maxBytes: 1024)
        XCTAssertEqual(chunk.data, bytes)
        XCTAssertEqual(chunk.sha256, manifest.sha256)
        XCTAssertTrue(chunk.eof)

        XCTAssertThrowsError(try inbox.begin(requestID: UUID(), maxBytes: 1024)) {
            XCTAssertEqual($0 as? ShippingInboxError, .anotherRequestIsActive)
        }

        XCTAssertThrowsError(try inbox.acknowledge(requestID: requestID, sha256: "wrong")) {
            XCTAssertEqual($0 as? ShippingInboxError, .digestMismatch)
        }
        let terminal = try inbox.acknowledge(requestID: requestID, sha256: manifest.sha256)
        XCTAssertEqual(terminal.state, .acknowledged)
        XCTAssertEqual(
            try inbox.acknowledge(requestID: requestID, sha256: manifest.sha256),
            terminal
        )
        XCTAssertEqual(try inbox.status(requestID: requestID), .acknowledged(terminal))
        let importDirectory = root
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: importDirectory.appendingPathComponent("source.pdf").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: importDirectory.appendingPathComponent("manifest.json").path
            )
        )
        XCTAssertNoThrow(try inbox.begin(requestID: UUID(), maxBytes: 1024))
    }

    func testBeginIsIdempotentOnlyForSameRequestAndLimit() throws {
        let requestID = UUID()
        let first = try inbox.begin(requestID: requestID, maxBytes: 1024)
        XCTAssertEqual(try inbox.begin(requestID: requestID, maxBytes: 1024), first)
        XCTAssertThrowsError(try inbox.begin(requestID: requestID, maxBytes: 2048))
        XCTAssertThrowsError(try inbox.begin(requestID: UUID(), maxBytes: 1024)) {
            XCTAssertEqual($0 as? ShippingInboxError, .anotherRequestIsActive)
        }
    }

    func testConcurrentBeginAllowsExactlyOneActiveRequest() throws {
        let firstInbox = try ShippingInbox(rootURL: root)
        let secondInbox = try ShippingInbox(rootURL: root)
        let start = DispatchSemaphore(value: 0)
        let completed = expectation(description: "both begin calls finish")
        completed.expectedFulfillmentCount = 2
        let firstResult = LockedResult()
        let secondResult = LockedResult()

        func launch(_ candidate: ShippingInbox, result: LockedResult) {
            DispatchQueue.global().async {
                start.wait()
                do {
                    _ = try candidate.begin(requestID: UUID(), maxBytes: 1024)
                    result.succeed()
                } catch {
                    result.set(error)
                }
                completed.fulfill()
            }
        }

        launch(firstInbox, result: firstResult)
        launch(secondInbox, result: secondResult)
        start.signal()
        start.signal()
        wait(for: [completed], timeout: 2)

        XCTAssertEqual([firstResult, secondResult].filter(\.didSucceed).count, 1)
        let errors = [firstResult.error, secondResult.error]
            .compactMap { $0 as? ShippingInboxError }
        XCTAssertEqual(errors, [.anotherRequestIsActive])
    }

    func testRejectsNonPDFAndOversizedPDF() throws {
        try inbox.begin(requestID: UUID(), maxBytes: 10)
        let nonPDF = root.appendingPathComponent("not.pdf")
        try Data("hello".utf8).write(to: nonPDF)
        XCTAssertThrowsError(try inbox.importPDF(from: nonPDF)) {
            XCTAssertEqual($0 as? ShippingInboxError, .sourceNotPDF)
        }

        let tooLarge = root.appendingPathComponent("large.pdf")
        try Data("%PDF-123456789".utf8).write(to: tooLarge)
        XCTAssertThrowsError(try inbox.importPDF(from: tooLarge)) {
            XCTAssertEqual($0 as? ShippingInboxError, .sourceTooLarge)
        }
    }

    func testAcceptsPDFHeaderWithinFirstKilobyte() throws {
        let requestID = UUID()
        let bytes = Data("Safari transport prefix\n%PDF-1.7\n%%EOF".utf8)
        let source = root.appendingPathComponent("prefixed.pdf")
        try bytes.write(to: source)

        try inbox.begin(requestID: requestID, maxBytes: 1024)
        let manifest = try inbox.importPDF(from: source)

        XCTAssertEqual(manifest.byteCount, bytes.count)
        XCTAssertEqual(try inbox.read(requestID: requestID, offset: 0, maxBytes: 1024).data, bytes)
    }

    func testChunkBoundsAreEnforced() throws {
        let requestID = UUID()
        let source = root.appendingPathComponent("fixture.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: source)
        try inbox.begin(requestID: requestID, maxBytes: 1024)
        try inbox.importPDF(from: source)

        XCTAssertThrowsError(try inbox.read(requestID: requestID, offset: -1, maxBytes: 1))
        XCTAssertThrowsError(
            try inbox.read(
                requestID: requestID,
                offset: 0,
                maxBytes: ShippingInbox.maximumChunkBytes + 1
            )
        )
    }

    func testFailureIsVisibleAndAValidRetryCanReplaceIt() throws {
        let requestID = UUID()
        try inbox.begin(requestID: requestID, maxBytes: 1024)

        let failure = try inbox.recordFailure(ShippingInboxError.sourceNotPDF)
        XCTAssertEqual(failure.code, "source_not_pdf")
        XCTAssertEqual(try inbox.status(requestID: requestID), .failed(failure))

        let bytes = Data("%PDF-1.4\nretry\n%%EOF".utf8)
        let source = root.appendingPathComponent("retry.pdf")
        try bytes.write(to: source)
        let manifest = try inbox.importPDF(from: source)
        XCTAssertEqual(try inbox.status(requestID: requestID), .ready(manifest))
    }

    func testRepeatedExtensionInvocationIsIdempotentForIdenticalPDF() throws {
        let requestID = UUID()
        let source = root.appendingPathComponent("fixture.pdf")
        try Data("%PDF-1.7\nrepeat\n%%EOF".utf8).write(to: source)
        try inbox.begin(requestID: requestID, maxBytes: 1024)

        let first = try inbox.importPDF(from: source)
        XCTAssertEqual(try inbox.importPDF(from: source), first)
    }

    func testRecoversSourceCommittedBeforeManifest() throws {
        let requestID = UUID()
        let bytes = Data("%PDF-1.7\nrecovered\n%%EOF".utf8)
        let source = root.appendingPathComponent("fixture.pdf")
        try bytes.write(to: source)
        try inbox.begin(requestID: requestID, maxBytes: 1024)

        let interruptedDirectory = root
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: interruptedDirectory,
            withIntermediateDirectories: true
        )
        try bytes.write(to: interruptedDirectory.appendingPathComponent("source.pdf"))

        let manifest = try inbox.importPDF(from: source)
        XCTAssertEqual(manifest.byteCount, bytes.count)
        XCTAssertEqual(try inbox.read(requestID: requestID, offset: 0, maxBytes: 1024).data, bytes)
    }

    func testCancelIsIdempotentAndReleasesTheActiveSlot() throws {
        let requestID = UUID()
        try inbox.begin(requestID: requestID, maxBytes: 1024)

        let terminal = try inbox.cancel(requestID: requestID)
        XCTAssertEqual(terminal.state, .cancelled)
        XCTAssertEqual(try inbox.cancel(requestID: requestID), terminal)
        XCTAssertEqual(try inbox.status(requestID: requestID), .cancelled(terminal))
        XCTAssertNoThrow(try inbox.begin(requestID: UUID(), maxBytes: 1024))
    }

    func testCancelPreservesAlreadyCommittedBytesUntilStalePurge() throws {
        let requestID = UUID()
        let bytes = Data("%PDF-1.7\ncommitted before cancel\n%%EOF".utf8)
        let source = root.appendingPathComponent("fixture.pdf")
        try bytes.write(to: source)
        try inbox.begin(requestID: requestID, maxBytes: 1024)
        _ = try inbox.importPDF(from: source)

        let terminal = try inbox.cancel(requestID: requestID)
        let importDirectory = root
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)

        XCTAssertEqual(try inbox.status(requestID: requestID), .cancelled(terminal))
        XCTAssertEqual(
            try Data(contentsOf: importDirectory.appendingPathComponent("source.pdf")),
            bytes
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: importDirectory.appendingPathComponent("manifest.json").path
            )
        )
    }

    func testCancelDuringCopyPreventsManifestCommit() throws {
        let reachedCopy = DispatchSemaphore(value: 0)
        let resumeCopy = DispatchSemaphore(value: 0)
        let copyResult = LockedResult()
        let copyingInbox = try ShippingInbox(
            rootURL: root,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            afterCopyChunk: { chunk in
                guard chunk == 1 else { return }
                reachedCopy.signal()
                resumeCopy.wait()
            }
        )
        let controllingInbox = try ShippingInbox(
            rootURL: root,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let requestID = UUID()
        let source = root.appendingPathComponent("large-fixture.pdf")
        var bytes = Data("%PDF-1.7\n".utf8)
        bytes.append(Data(repeating: 0x41, count: ShippingInbox.maximumChunkBytes + 128))
        try bytes.write(to: source)
        try copyingInbox.begin(requestID: requestID, maxBytes: bytes.count)

        let completed = expectation(description: "copy exits after cancellation")
        DispatchQueue.global().async {
            do {
                _ = try copyingInbox.importPDF(from: source)
            } catch {
                copyResult.set(error)
            }
            completed.fulfill()
        }

        XCTAssertEqual(reachedCopy.wait(timeout: .now() + 2), .success)
        let terminal = try controllingInbox.cancel(requestID: requestID)
        resumeCopy.signal()
        wait(for: [completed], timeout: 2)

        XCTAssertEqual(copyResult.error as? ShippingInboxError, .requestCancelled)
        XCTAssertEqual(try controllingInbox.status(requestID: requestID), .cancelled(terminal))
        let importDirectory = root
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: importDirectory.appendingPathComponent("manifest.json").path
            )
        )
    }

    func testReadRejectsSourceWhoseExactLengthNoLongerMatchesManifest() throws {
        let requestID = UUID()
        let source = root.appendingPathComponent("fixture.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: source)
        try inbox.begin(requestID: requestID, maxBytes: 1024)
        try inbox.importPDF(from: source)

        let committed = root
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("source.pdf")
        try Data("%PDF-1.4\ntruncated".utf8).write(to: committed)

        XCTAssertThrowsError(try inbox.read(requestID: requestID, offset: 0, maxBytes: 1024)) {
            XCTAssertEqual($0 as? ShippingInboxError, .importCorrupted)
        }
    }

    func testActiveRequestsAreDiscoverableSoALostRequestIDCanBeRecovered() throws {
        XCTAssertTrue(try inbox.activeRequests().isEmpty)

        let requestID = UUID()
        try inbox.begin(requestID: requestID, maxBytes: 1024)
        XCTAssertEqual(try inbox.activeRequests().map(\.requestID), [requestID])

        // A host that lost the id is otherwise locked out until the stale purge.
        let recovered = try XCTUnwrap(inbox.activeRequests().first)
        _ = try inbox.cancel(requestID: recovered.requestID)

        XCTAssertTrue(try inbox.activeRequests().isEmpty)
        XCTAssertNoThrow(try inbox.begin(requestID: UUID(), maxBytes: 1024))
    }

    func testAcknowledgedRequestIsNotReportedAsActive() throws {
        let requestID = UUID()
        let source = root.appendingPathComponent("fixture.pdf")
        try Data("%PDF-1.7\nactive\n%%EOF".utf8).write(to: source)
        try inbox.begin(requestID: requestID, maxBytes: 1024)
        let manifest = try inbox.importPDF(from: source)
        XCTAssertEqual(try inbox.activeRequests().map(\.requestID), [requestID])

        _ = try inbox.acknowledge(requestID: requestID, sha256: manifest.sha256)
        XCTAssertTrue(try inbox.activeRequests().isEmpty)
    }

    func testTornRequestFileDoesNotWedgeTheInbox() throws {
        let requestID = UUID()
        try inbox.begin(requestID: requestID, maxBytes: 1024)
        let requestFile = root
            .appendingPathComponent("Requests", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased() + ".json")
        try Data("{ truncated".utf8).write(to: requestFile)

        // init purges, and every RPC constructs a fresh inbox: a throw here used
        // to fail the constructor and lock the feature out permanently.
        let restarted = try ShippingInbox(
            rootURL: root,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestFile.path))
        XCTAssertTrue(try restarted.activeRequests().isEmpty)
        XCTAssertNoThrow(try restarted.begin(requestID: UUID(), maxBytes: 1024))
    }

    func testTornTerminalReceiptKeepsTheRequestVisibleInsteadOfWedging() throws {
        let requestID = UUID()
        try inbox.begin(requestID: requestID, maxBytes: 1024)
        // A crash between writing the receipt and clearing the request file leaves
        // both on disk; corrupt the receipt to simulate the torn write.
        let importDirectory = root
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: importDirectory,
            withIntermediateDirectories: true
        )
        try Data("{ truncated".utf8).write(
            to: importDirectory.appendingPathComponent("terminal.json")
        )

        let restarted = try ShippingInbox(
            rootURL: root,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        // Fail safe: still visible and cancellable, rather than unopenable.
        XCTAssertEqual(try restarted.activeRequests().map(\.requestID), [requestID])
    }

    func testInitializationPurgesRequestsOlderThanRetentionWindow() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let first = try ShippingInbox(rootURL: root, now: { clock.value })
        let oldRequest = UUID()
        try first.begin(requestID: oldRequest, maxBytes: 1024)

        clock.value = clock.value.addingTimeInterval(ShippingInbox.retentionInterval + 1)
        let restarted = try ShippingInbox(rootURL: root, now: { clock.value })

        XCTAssertThrowsError(try restarted.status(requestID: oldRequest)) {
            XCTAssertEqual($0 as? ShippingInboxError, .noActiveRequest)
        }
        XCTAssertNoThrow(try restarted.begin(requestID: UUID(), maxBytes: 1024))
    }

    func testInitializationPurgesOldTerminalReceipt() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let first = try ShippingInbox(rootURL: root, now: { clock.value })
        let requestID = UUID()
        let source = root.appendingPathComponent("fixture.pdf")
        try Data("%PDF-1.7\n%%EOF".utf8).write(to: source)
        try first.begin(requestID: requestID, maxBytes: 1024)
        let manifest = try first.importPDF(from: source)
        _ = try first.acknowledge(requestID: requestID, sha256: manifest.sha256)

        clock.value = clock.value.addingTimeInterval(ShippingInbox.retentionInterval + 1)
        let restarted = try ShippingInbox(rootURL: root, now: { clock.value })

        XCTAssertThrowsError(try restarted.status(requestID: requestID)) {
            XCTAssertEqual($0 as? ShippingInboxError, .noActiveRequest)
        }
    }

    func testInitializationPurgesCancelledCommittedSourceAfterRetention() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let first = try ShippingInbox(rootURL: root, now: { clock.value })
        let requestID = UUID()
        let source = root.appendingPathComponent("fixture.pdf")
        try Data("%PDF-1.7\n%%EOF".utf8).write(to: source)
        try first.begin(requestID: requestID, maxBytes: 1024)
        _ = try first.importPDF(from: source)
        _ = try first.cancel(requestID: requestID)

        let importDirectory = root
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importDirectory.path))

        clock.value = clock.value.addingTimeInterval(ShippingInbox.retentionInterval + 1)
        let restarted = try ShippingInbox(rootURL: root, now: { clock.value })

        XCTAssertFalse(FileManager.default.fileExists(atPath: importDirectory.path))
        XCTAssertThrowsError(try restarted.status(requestID: requestID)) {
            XCTAssertEqual($0 as? ShippingInboxError, .noActiveRequest)
        }
    }

    func testExtensionCallbackTimeoutIsBoundedAndLateCompletionIsIgnored() async throws {
        let lateCompletion = LockedCompletion()
        do {
            _ = try await awaitShippingImport(timeoutSeconds: 0.01) { claim, completion in
                lateCompletion.store(claim: claim, completion: completion)
                return nil
            }
            XCTFail("Expected extension timeout")
        } catch {
            XCTAssertEqual(error as? ShippingInboxError, .extensionTimeout)
        }

        XCTAssertFalse(lateCompletion.claim())
        lateCompletion.complete(
            .success(
                ShippingImportManifest(
                    requestID: UUID(),
                    byteCount: 1,
                    sha256: "late",
                    createdAt: Date()
                )
            )
        )
    }

    func testImportThatBlocksAfterClaimingStillTimesOut() async throws {
        let release = DispatchSemaphore(value: 0)
        let lateCompletionReturned = expectation(
            description: "the blocked import finishes after the deadline"
        )

        do {
            _ = try await awaitShippingImport(timeoutSeconds: 0.05) { claim, completion in
                DispatchQueue.global().async {
                    guard claim() else { return }
                    // A copy that blocks after claiming — slow provider, or the inbox
                    // lock held by a wedged peer. This used to be unreachable by the
                    // deadline, leaving the continuation suspended forever.
                    release.wait()
                    completion(
                        .success(
                            ShippingImportManifest(
                                requestID: UUID(),
                                byteCount: 1,
                                sha256: "late",
                                createdAt: Date()
                            )
                        )
                    )
                    lateCompletionReturned.fulfill()
                }
                return nil
            }
            XCTFail("Expected extension timeout")
        } catch {
            XCTAssertEqual(error as? ShippingInboxError, .extensionTimeout)
        }

        // Completing afterwards must be dropped, not resume the continuation twice.
        release.signal()
        await fulfillment(of: [lateCompletionReturned], timeout: 2)
    }

    func testShareExtensionIsOfferedForOnePDFAcrossSafariItems() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = repositoryRoot
            .appendingPathComponent("ShippingShareExtension")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let extensionDictionary = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(
            extensionDictionary["NSExtensionAttributes"] as? [String: Any]
        )
        let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String)
        XCTAssertFalse(rule.contains("TRUEPREDICATE"))
        let predicate = NSPredicate(format: rule)

        func context(_ typeSets: [[String]], extraItems: Int = 0) -> [String: Any] {
            let attachments = typeSets.map { ["registeredTypeIdentifiers": $0] }
            var items: [[String: Any]] = [["attachments": attachments]]
            items.append(contentsOf: Array(repeating: ["attachments": []], count: extraItems))
            return ["extensionItems": items]
        }

        XCTAssertTrue(predicate.evaluate(with: context([["com.adobe.pdf", "public.file-url"]])))
        XCTAssertTrue(predicate.evaluate(with: context([["com.adobe.pdf"], ["public.url"]])))
        XCTAssertFalse(predicate.evaluate(with: context([["public.png"]])))
        XCTAssertFalse(predicate.evaluate(with: context([["com.adobe.pdf"], ["com.adobe.pdf"]])))
        XCTAssertTrue(predicate.evaluate(with: context([["com.adobe.pdf"]], extraItems: 1)))
        XCTAssertFalse(predicate.evaluate(with: context([])))
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedSuccess = false

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var didSucceed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedSuccess
    }

    func succeed() {
        lock.lock()
        storedSuccess = true
        lock.unlock()
    }

    func set(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(_ value: Date) {
        storedValue = value
    }

    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class LockedCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedClaim: (@Sendable () -> Bool)?
    private var stored: (@Sendable (Result<ShippingImportManifest, Error>) -> Void)?

    func store(
        claim: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (Result<ShippingImportManifest, Error>) -> Void
    ) {
        lock.lock()
        storedClaim = claim
        stored = completion
        lock.unlock()
    }

    func claim() -> Bool {
        lock.lock()
        let claim = storedClaim
        lock.unlock()
        return claim?() ?? false
    }

    func complete(_ result: Result<ShippingImportManifest, Error>) {
        lock.lock()
        let completion = stored
        lock.unlock()
        completion?(result)
    }
}
