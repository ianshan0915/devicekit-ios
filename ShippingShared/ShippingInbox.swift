import CryptoKit
import Darwin
import Foundation

public enum ShippingInboxError: Error, Equatable, LocalizedError {
    case invalidRequestID
    case invalidMaximumBytes
    case appGroupUnavailable
    case anotherRequestIsActive
    case noActiveRequest
    case multipleActiveRequests
    case importAlreadyCompleted
    case requestAcknowledged
    case requestCancelled
    case sourceNotPDF
    case sourceTooLarge
    case invalidReadRange
    case digestMismatch
    case importCorrupted
    case extensionTimeout

    public var errorDescription: String? {
        switch self {
        case .invalidRequestID: "The shipping request is invalid."
        case .invalidMaximumBytes: "The shipping file size limit is invalid."
        case .appGroupUnavailable: "YJ Commerce sharing is unavailable on this phone."
        case .anotherRequestIsActive: "Another shipping label is already being saved."
        case .noActiveRequest: "Start saving the shipping label in YJ Commerce first."
        case .multipleActiveRequests: "More than one shipping request is active."
        case .importAlreadyCompleted: "This shipping label was already saved."
        case .requestAcknowledged: "This shipping label was already confirmed."
        case .requestCancelled: "Saving this shipping label was cancelled."
        case .sourceNotPDF: "The shared file is not a PDF."
        case .sourceTooLarge: "The shared PDF is too large."
        case .invalidReadRange: "The requested PDF range is invalid."
        case .digestMismatch: "The shipping label checksum does not match."
        case .importCorrupted: "The saved shipping label is incomplete."
        case .extensionTimeout: "The shared PDF took too long to save."
        }
    }

    public var diagnosticCode: String {
        switch self {
        case .invalidRequestID: "invalid_request_id"
        case .invalidMaximumBytes: "invalid_maximum_bytes"
        case .appGroupUnavailable: "app_group_unavailable"
        case .anotherRequestIsActive: "another_request_active"
        case .noActiveRequest: "no_active_request"
        case .multipleActiveRequests: "multiple_active_requests"
        case .importAlreadyCompleted: "import_already_completed"
        case .requestAcknowledged: "request_acknowledged"
        case .requestCancelled: "request_cancelled"
        case .sourceNotPDF: "source_not_pdf"
        case .sourceTooLarge: "source_too_large"
        case .invalidReadRange: "invalid_read_range"
        case .digestMismatch: "digest_mismatch"
        case .importCorrupted: "import_corrupted"
        case .extensionTimeout: "extension_timeout"
        }
    }
}

public struct ShippingImportRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let maxBytes: Int
    public let createdAt: Date
}

public struct ShippingImportManifest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let byteCount: Int
    public let sha256: String
    public let createdAt: Date
}

public struct ShippingImportFailure: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let code: String
    public let message: String
    public let createdAt: Date
}

public enum ShippingImportTerminalState: String, Codable, Equatable, Sendable {
    case acknowledged
    case cancelled
}

public struct ShippingImportTerminal: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let state: ShippingImportTerminalState
    public let sha256: String?
    public let createdAt: Date
}

public enum ShippingImportStatus: Equatable, Sendable {
    case waiting
    case ready(ShippingImportManifest)
    case failed(ShippingImportFailure)
    case acknowledged(ShippingImportTerminal)
    case cancelled(ShippingImportTerminal)
}

public struct ShippingImportChunk: Equatable, Sendable {
    public let data: Data
    public let offset: Int
    public let totalBytes: Int
    public let sha256: String
    public let eof: Bool
}

private final class ShippingImportContinuationGate: @unchecked Sendable {
    private enum State {
        case waiting(CheckedContinuation<ShippingImportManifest, Error>)
        case importing(CheckedContinuation<ShippingImportManifest, Error>)
        case finished
    }

    private let lock = NSLock()
    private var state: State

    init(_ continuation: CheckedContinuation<ShippingImportManifest, Error>) {
        state = .waiting(continuation)
    }

    func claimImport() -> Bool {
        lock.withLock {
            guard case .waiting(let continuation) = state else { return false }
            state = .importing(continuation)
            return true
        }
    }

    func finish(with result: Result<ShippingImportManifest, Error>) {
        let continuation: CheckedContinuation<ShippingImportManifest, Error>? = lock.withLock {
            guard case .importing(let continuation) = state else { return nil }
            state = .finished
            return continuation
        }
        continuation?.resume(with: result)
    }

    /// Fires from `waiting` *or* `importing`. Covering only `waiting` left the
    /// continuation unresumable once the provider callback had started: a copy that
    /// blocked — a slow provider, or the inbox lock held by a wedged peer — hung the
    /// Share Extension on "Saving shipping label…" with no deadline at all.
    ///
    /// Racing a copy that is about to succeed is safe: `finish` then finds
    /// `finished` and is dropped, and the manifest it committed is still on disk for
    /// the host to observe via `status`.
    func timeout() -> Bool {
        let continuation: CheckedContinuation<ShippingImportManifest, Error>? = lock.withLock {
            switch state {
            case .waiting(let continuation), .importing(let continuation):
                state = .finished
                return continuation
            case .finished:
                return nil
            }
        }
        continuation?.resume(throwing: ShippingInboxError.extensionTimeout)
        return continuation != nil
    }
}

/// Bridges an item-provider callback into one bounded async import. `timeoutSeconds`
/// is the budget for the whole operation — waiting for the provider *and* copying
/// what it hands back — so no path can leave the caller suspended forever. The gate
/// deliberately accepts only the first callback, so a provider completing after the
/// timeout cannot resume the continuation twice.
public func awaitShippingImport(
    timeoutSeconds: TimeInterval,
    start: (
        @escaping @Sendable () -> Bool,
        @escaping @Sendable (Result<ShippingImportManifest, Error>) -> Void
    ) -> Progress?
) async throws -> ShippingImportManifest {
    try await withCheckedThrowingContinuation { continuation in
        let gate = ShippingImportContinuationGate(continuation)
        let progress = start(
            { gate.claimImport() },
            { result in gate.finish(with: result) }
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            if gate.timeout() {
                progress?.cancel()
            }
        }
    }
}

/// A correlated, fail-closed App Group inbox shared by the runner and Share Extension.
///
/// The host creates one request before invoking the extension. The extension copies
/// one PDF to a private partial, fsyncs it, atomically renames it, and commits the
/// manifest last. Both ACK and cancel leave a small terminal receipt so retries
/// are idempotent.
///
/// Only a digest-matching ACK removes the PDF bytes. Cancel cannot prove the host
/// received them, so it releases the request slot but deliberately preserves an
/// already-committed source and leaves it for `purgeStale` to remove after
/// `retentionInterval` — a cancelled label stays on the phone for up to 24 hours.
public final class ShippingInbox: @unchecked Sendable {
    public static let protocolVersion = 1
    public static let appGroupIdentifier = "group.nl.yj-commerce.media.shipping"
    public static let maximumAllowedBytes = 25 * 1024 * 1024
    public static let maximumChunkBytes = 512 * 1024
    public static let retentionInterval: TimeInterval = 24 * 60 * 60

    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let now: @Sendable () -> Date
    private let afterCopyChunk: (@Sendable (Int) -> Void)?
    private let lock = NSLock()

    public convenience init(appGroupIdentifier: String = ShippingInbox.appGroupIdentifier) throws {
        guard let rootURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ShippingInboxError.appGroupUnavailable
        }
        try self.init(rootURL: rootURL)
    }

    public convenience init(
        rootURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try self.init(rootURL: rootURL, fileManager: fileManager, now: now, afterCopyChunk: nil)
    }

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        afterCopyChunk: (@Sendable (Int) -> Void)?
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
        self.afterCopyChunk = afterCopyChunk
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(at: requestsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: importsURL, withIntermediateDirectories: true)
        _ = try purgeStale()
    }

    @discardableResult
    public func begin(requestID: UUID, maxBytes: Int) throws -> ShippingImportRequest {
        try withExclusiveLock {
            guard maxBytes > 0, maxBytes <= Self.maximumAllowedBytes else {
                throw ShippingInboxError.invalidMaximumBytes
            }

            let requestedURL = requestURL(for: requestID)
            if fileManager.fileExists(atPath: requestedURL.path) {
                let existing = try decode(ShippingImportRequest.self, from: requestedURL)
                guard existing.maxBytes == maxBytes else {
                    throw ShippingInboxError.invalidMaximumBytes
                }
                return existing
            }
            if let terminal = try terminalIfPresent(requestID: requestID) {
                throw terminal.state == .acknowledged
                    ? ShippingInboxError.requestAcknowledged
                    : ShippingInboxError.requestCancelled
            }

            guard try activeRequestsUnlocked().isEmpty else {
                throw ShippingInboxError.anotherRequestIsActive
            }
            let request = ShippingImportRequest(
                requestID: requestID,
                maxBytes: maxBytes,
                createdAt: now()
            )
            try writeJSONAtomically(request, to: requestedURL)
            return request
        }
    }

    /// Every request that has not reached a terminal receipt yet — normally one,
    /// or none. A host that lost its request id (session crash, or the phone moved
    /// to a different host) recovers it here and cancels it, instead of being
    /// locked out by `anotherRequestIsActive` until `retentionInterval` elapses.
    public func activeRequests() throws -> [ShippingImportRequest] {
        try withExclusiveLock { try activeRequestsUnlocked() }
    }

    @discardableResult
    public func importPDF(from sourceURL: URL) throws -> ShippingImportManifest {
        let request = try withExclusiveLock { try requestForImportUnlocked() }
        guard sourceURL.isFileURL else { throw ShippingInboxError.sourceNotPDF }

        let importDirectory = importURL(for: request.requestID)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        let partialURL = importDirectory.appendingPathComponent(
            "source.\(UUID().uuidString.lowercased()).partial"
        )

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let headerWindow = try input.read(upToCount: 1024) ?? Data()
        guard headerWindow.range(of: Data("%PDF-".utf8)) != nil else {
            throw ShippingInboxError.sourceNotPDF
        }
        try input.seek(toOffset: 0)

        guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try protectFile(at: partialURL)

        let output = try FileHandle(forWritingTo: partialURL)
        var hasher = SHA256()
        var byteCount = 0
        var chunkIndex = 0
        do {
            while let data = try input.read(upToCount: Self.maximumChunkBytes), !data.isEmpty {
                if try isCancelled(requestID: request.requestID) {
                    throw ShippingInboxError.requestCancelled
                }
                byteCount += data.count
                guard byteCount <= request.maxBytes,
                      byteCount <= Self.maximumAllowedBytes else {
                    throw ShippingInboxError.sourceTooLarge
                }
                hasher.update(data: data)
                try output.write(contentsOf: data)
                chunkIndex += 1
                afterCopyChunk?(chunkIndex)
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: partialURL)
            throw error
        }

        let copiedSize = try fileSize(at: partialURL)
        guard copiedSize == byteCount else {
            try? fileManager.removeItem(at: partialURL)
            throw ShippingInboxError.importCorrupted
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        return try withExclusiveLock {
            if let terminal = try terminalIfPresent(requestID: request.requestID) {
                try? fileManager.removeItem(at: partialURL)
                throw terminal.state == .acknowledged
                    ? ShippingInboxError.requestAcknowledged
                    : ShippingInboxError.requestCancelled
            }

            let manifestDestination = manifestURL(for: request.requestID)
            if fileManager.fileExists(atPath: manifestDestination.path) {
                let existing = try decode(ShippingImportManifest.self, from: manifestDestination)
                try? fileManager.removeItem(at: partialURL)
                guard existing.byteCount == byteCount, existing.sha256 == digest else {
                    throw ShippingInboxError.importAlreadyCompleted
                }
                return existing
            }

            let sourceDestination = sourceURLForImport(request.requestID)
            if fileManager.fileExists(atPath: sourceDestination.path) {
                let existingSize = try fileSize(at: sourceDestination)
                let existingDigest = try sha256(at: sourceDestination)
                if existingSize == byteCount, existingDigest == digest {
                    try fileManager.removeItem(at: partialURL)
                } else {
                    try fileManager.removeItem(at: sourceDestination)
                    try fileManager.moveItem(at: partialURL, to: sourceDestination)
                }
            } else {
                try fileManager.moveItem(at: partialURL, to: sourceDestination)
            }
            try protectFile(at: sourceDestination)
            try synchronizeDirectory(at: importDirectory)

            let failureDestination = failureURL(for: request.requestID)
            if fileManager.fileExists(atPath: failureDestination.path) {
                try fileManager.removeItem(at: failureDestination)
            }

            let manifest = ShippingImportManifest(
                requestID: request.requestID,
                byteCount: byteCount,
                sha256: digest,
                createdAt: now()
            )
            try writeJSONAtomically(manifest, to: manifestDestination)
            return manifest
        }
    }

    @discardableResult
    public func recordFailure(_ error: Error) throws -> ShippingImportFailure {
        try withExclusiveLock {
            let request = try requestForImportUnlocked()
            if fileManager.fileExists(atPath: manifestURL(for: request.requestID).path) {
                throw ShippingInboxError.importAlreadyCompleted
            }
            let destination = failureURL(for: request.requestID)
            if fileManager.fileExists(atPath: destination.path) {
                return try decode(ShippingImportFailure.self, from: destination)
            }

            let nsError = error as NSError
            let failure = ShippingImportFailure(
                requestID: request.requestID,
                code: (error as? ShippingInboxError)?.diagnosticCode
                    ?? "\(nsError.domain):\(nsError.code)",
                message: error.localizedDescription,
                createdAt: now()
            )
            try fileManager.createDirectory(
                at: importURL(for: request.requestID),
                withIntermediateDirectories: true
            )
            try writeJSONAtomically(failure, to: destination)
            return failure
        }
    }

    public func status(requestID: UUID) throws -> ShippingImportStatus {
        try withExclusiveLock { try statusUnlocked(requestID: requestID) }
    }

    public func read(requestID: UUID, offset: Int, maxBytes: Int) throws -> ShippingImportChunk {
        try withExclusiveLock {
            guard offset >= 0, maxBytes > 0, maxBytes <= Self.maximumChunkBytes else {
                throw ShippingInboxError.invalidReadRange
            }
            guard case .ready(let manifest) = try statusUnlocked(requestID: requestID) else {
                throw ShippingInboxError.noActiveRequest
            }
            guard offset <= manifest.byteCount else { throw ShippingInboxError.invalidReadRange }

            let sourceURL = sourceURLForImport(requestID)
            guard fileManager.fileExists(atPath: sourceURL.path),
                  try fileSize(at: sourceURL) == manifest.byteCount else {
                throw ShippingInboxError.importCorrupted
            }
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let expected = min(maxBytes, manifest.byteCount - offset)
            let data = try handle.read(upToCount: expected) ?? Data()
            guard data.count == expected else { throw ShippingInboxError.importCorrupted }
            return ShippingImportChunk(
                data: data,
                offset: offset,
                totalBytes: manifest.byteCount,
                sha256: manifest.sha256,
                eof: offset + data.count == manifest.byteCount
            )
        }
    }

    @discardableResult
    public func acknowledge(requestID: UUID, sha256 suppliedDigest: String) throws
        -> ShippingImportTerminal {
        try withExclusiveLock {
            if let terminal = try terminalIfPresent(requestID: requestID) {
                guard terminal.state == .acknowledged else {
                    throw ShippingInboxError.requestCancelled
                }
                guard terminal.sha256 == suppliedDigest.lowercased() else {
                    throw ShippingInboxError.digestMismatch
                }
                try cleanupImportUnlocked(requestID: requestID)
                return terminal
            }

            guard case .ready(let manifest) = try statusUnlocked(requestID: requestID) else {
                throw ShippingInboxError.noActiveRequest
            }
            let normalizedDigest = suppliedDigest.lowercased()
            guard manifest.sha256 == normalizedDigest else {
                throw ShippingInboxError.digestMismatch
            }
            guard try fileSize(at: sourceURLForImport(requestID)) == manifest.byteCount else {
                throw ShippingInboxError.importCorrupted
            }

            let terminal = ShippingImportTerminal(
                requestID: requestID,
                state: .acknowledged,
                sha256: manifest.sha256,
                createdAt: now()
            )
            try writeJSONAtomically(terminal, to: terminalURL(for: requestID))
            try cleanupImportUnlocked(requestID: requestID)
            return terminal
        }
    }

    @discardableResult
    public func cancel(requestID: UUID) throws -> ShippingImportTerminal {
        try withExclusiveLock {
            if let terminal = try terminalIfPresent(requestID: requestID) {
                guard terminal.state == .cancelled else {
                    throw ShippingInboxError.requestAcknowledged
                }
                try cleanupImportUnlocked(requestID: requestID, preservingCommittedSource: true)
                return terminal
            }
            guard fileManager.fileExists(atPath: requestURL(for: requestID).path) else {
                throw ShippingInboxError.noActiveRequest
            }

            try fileManager.createDirectory(
                at: importURL(for: requestID),
                withIntermediateDirectories: true
            )
            let terminal = ShippingImportTerminal(
                requestID: requestID,
                state: .cancelled,
                sha256: nil,
                createdAt: now()
            )
            try writeJSONAtomically(terminal, to: terminalURL(for: requestID))
            // Cancellation releases the active request but must not destroy a
            // source that was already committed. Only a digest-matching ACK
            // may remove those bytes; stale retention eventually removes an
            // abandoned cancelled import.
            try cleanupImportUnlocked(requestID: requestID, preservingCommittedSource: true)
            return terminal
        }
    }

    @discardableResult
    public func purgeStale(olderThan retention: TimeInterval = ShippingInbox.retentionInterval) throws
        -> Int {
        try withExclusiveLock {
            let cutoff = now().addingTimeInterval(-retention)
            var removed = 0

            for url in try requestFiles() {
                guard let request = try? decode(ShippingImportRequest.self, from: url) else {
                    // A readable-but-undecodable request is a torn write. It carries
                    // no createdAt, so retention can never age it out, and every RPC
                    // constructs a fresh inbox — leaving it would wedge the feature
                    // permanently. A file we cannot even read is left alone: that is
                    // more likely transient IO than garbage.
                    if (try? Data(contentsOf: url)) != nil {
                        try? fileManager.removeItem(at: url)
                        removed += 1
                    }
                    continue
                }
                guard request.createdAt < cutoff else { continue }
                try? fileManager.removeItem(at: url)
                let directory = importURL(for: request.requestID)
                if fileManager.fileExists(atPath: directory.path) {
                    try? fileManager.removeItem(at: directory)
                }
                removed += 1
            }

            let importDirectories = (try? fileManager.contentsOfDirectory(
                at: importsURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for directory in importDirectories {
                guard let requestID = UUID(uuidString: directory.lastPathComponent),
                      !fileManager.fileExists(atPath: requestURL(for: requestID).path),
                      importDate(requestID: requestID, directory: directory) < cutoff else {
                    continue
                }
                try? fileManager.removeItem(at: directory)
                removed += 1
            }
            return removed
        }
    }

    private var requestsURL: URL { rootURL.appendingPathComponent("Requests", isDirectory: true) }
    private var importsURL: URL { rootURL.appendingPathComponent("Imports", isDirectory: true) }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            let lockURL = rootURL.appendingPathComponent(".inbox.lock")
            let descriptor = lockURL.path.withCString {
                Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    private func requestURL(for requestID: UUID) -> URL {
        requestsURL.appendingPathComponent(requestID.uuidString.lowercased() + ".json")
    }

    private func importURL(for requestID: UUID) -> URL {
        importsURL.appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
    }

    private func sourceURLForImport(_ requestID: UUID) -> URL {
        importURL(for: requestID).appendingPathComponent("source.pdf")
    }

    private func manifestURL(for requestID: UUID) -> URL {
        importURL(for: requestID).appendingPathComponent("manifest.json")
    }

    private func failureURL(for requestID: UUID) -> URL {
        importURL(for: requestID).appendingPathComponent("failure.json")
    }

    private func terminalURL(for requestID: UUID) -> URL {
        importURL(for: requestID).appendingPathComponent("terminal.json")
    }

    private func requestFiles() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: requestsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    /// Scanning skips entries it cannot read. One torn write must not make the
    /// whole inbox unopenable — `init` purges and every RPC builds a fresh
    /// instance, so a throw here would fail closed forever. Lookups keyed by a
    /// specific request id stay strict and still surface corruption.
    private func activeRequestsUnlocked() throws -> [ShippingImportRequest] {
        try requestFiles()
            .compactMap { try? decode(ShippingImportRequest.self, from: $0) }
            .filter { request in
                // An unreadable receipt is read as "no receipt": the request stays
                // visible and cancellable rather than silently releasing bytes that
                // may never have been acknowledged.
                ((try? terminalIfPresent(requestID: request.requestID)) ?? nil) == nil
            }
    }

    private func requestForImportUnlocked() throws -> ShippingImportRequest {
        let active = try activeRequestsUnlocked()
        guard !active.isEmpty else { throw ShippingInboxError.noActiveRequest }
        guard active.count == 1 else { throw ShippingInboxError.multipleActiveRequests }
        return active[0]
    }

    private func statusUnlocked(requestID: UUID) throws -> ShippingImportStatus {
        if let terminal = try terminalIfPresent(requestID: requestID) {
            return terminal.state == .acknowledged
                ? .acknowledged(terminal)
                : .cancelled(terminal)
        }
        guard fileManager.fileExists(atPath: requestURL(for: requestID).path) else {
            throw ShippingInboxError.noActiveRequest
        }
        let manifestURL = manifestURL(for: requestID)
        if fileManager.fileExists(atPath: manifestURL.path) {
            return .ready(try decode(ShippingImportManifest.self, from: manifestURL))
        }
        let failureURL = failureURL(for: requestID)
        if fileManager.fileExists(atPath: failureURL.path) {
            return .failed(try decode(ShippingImportFailure.self, from: failureURL))
        }
        return .waiting
    }

    private func terminalIfPresent(requestID: UUID) throws -> ShippingImportTerminal? {
        let url = terminalURL(for: requestID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decode(ShippingImportTerminal.self, from: url)
    }

    private func isCancelled(requestID: UUID) throws -> Bool {
        try terminalIfPresent(requestID: requestID)?.state == .cancelled
    }

    private func cleanupImportUnlocked(
        requestID: UUID,
        preservingCommittedSource: Bool = false
    ) throws {
        let directory = importURL(for: requestID)
        if fileManager.fileExists(atPath: directory.path) {
            var preservedNames: Set<String> = ["terminal.json"]
            if preservingCommittedSource {
                preservedNames.formUnion(["source.pdf", "manifest.json"])
            }
            for url in try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) where !preservedNames.contains(url.lastPathComponent) {
                try fileManager.removeItem(at: url)
            }
        }
        let request = requestURL(for: requestID)
        if fileManager.fileExists(atPath: request.path) {
            try fileManager.removeItem(at: request)
        }
    }

    /// Non-throwing for the same reason as `activeRequestsUnlocked`: this only
    /// decides whether a directory has aged out, and must not fail the purge.
    private func importDate(requestID: UUID, directory: URL) -> Date {
        if let terminal = (try? terminalIfPresent(requestID: requestID)) ?? nil {
            return terminal.createdAt
        }
        if let manifest = try? decode(
            ShippingImportManifest.self, from: manifestURL(for: requestID)
        ) {
            return manifest.createdAt
        }
        if let failure = try? decode(
            ShippingImportFailure.self, from: failureURL(for: requestID)
        ) {
            return failure.createdAt
        }
        return (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func writeJSONAtomically<T: Encodable>(_ value: T, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partial = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).partial"
        )
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try protectFile(at: partial)
        let handle = try FileHandle(forWritingTo: partial)
        do {
            try handle.write(contentsOf: encoder.encode(value))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: partial)
            throw error
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: partial)
            throw ShippingInboxError.importAlreadyCompleted
        }
        try fileManager.moveItem(at: partial, to: destination)
        try protectFile(at: destination)
        try synchronizeDirectory(at: destination.deletingLastPathComponent())
    }

    private func protectFile(at url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func fileSize(at url: URL) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ShippingInboxError.importCorrupted
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw ShippingInboxError.importCorrupted }
        return size
    }

    private func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: Self.maximumChunkBytes), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
