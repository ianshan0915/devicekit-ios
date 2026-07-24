// Saves a host-supplied file onto the device. Images and videos go to the
// camera roll via PHPhotoLibrary; everything else is written to the runner's
// Documents container, where the Files app can reach it.
//
// Lives in Streamer/ because that folder is a filesystem-synchronized group on
// the UITests target — files here compile with no project.pbxproj entry. The
// natural home is JSONRPC/Handlers/, whose files are listed individually.
//
// Authorization is .readWrite, NOT .addOnly: Xcode's runner template ships
// NSPhotoLibraryUsageDescription but not NSPhotoLibraryAddUsageDescription, and
// requesting .addOnly without its usage string terminates the process.
import Foundation
import Photos
import UniformTypeIdentifiers
import os

struct FileSaveRequest: Codable {
    let filename: String
    let dataBase64: String
}

@MainActor
struct FileSaveMethodHandler: RPCMethodHandler {
    static let methodName = "device.saveFile"

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )

    /// True when the extension names an image or video, i.e. camera-roll material.
    private func isMedia(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    func execute(params: JSONValue?) async throws -> JSONValue {
        let request = try decodeParams(FileSaveRequest.self, from: params)

        guard let data = Data(base64Encoded: request.dataBase64) else {
            throw RPCMethodError.invalidParams("dataBase64 is not valid base64")
        }
        guard !request.filename.isEmpty else {
            throw RPCMethodError.invalidParams("filename must not be empty")
        }

        if isMedia(request.filename) {
            try await saveToPhotos(data: data, filename: request.filename)
            logger.info("saved \(data.count) bytes to photos: \(request.filename)")
            return .object(["saved": .bool(true), "destination": .string("photos")])
        }

        try saveToDocuments(data: data, filename: request.filename)
        logger.info("saved \(data.count) bytes to documents: \(request.filename)")
        return .object(["saved": .bool(true), "destination": .string("documents")])
    }

    private func saveToPhotos(data: Data, filename: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw RPCMethodError.internalError(
                "photo library access not granted (status: \(status.rawValue))"
            )
        }
        let isVideo = UTType(filenameExtension: (filename as NSString).pathExtension)?
            .conforms(to: .movie) ?? false
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.addResource(with: isVideo ? .video : .photo, data: data, options: nil)
            }
        } catch {
            throw RPCMethodError.internalError("photo save failed: \(error.localizedDescription)")
        }
    }

    private func saveToDocuments(data: Data, filename: String) throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Strip any path components: the host controls this string.
        let safe = (filename as NSString).lastPathComponent
        do {
            try data.write(to: docs.appendingPathComponent(safe), options: .atomic)
        } catch {
            throw RPCMethodError.internalError("file write failed: \(error.localizedDescription)")
        }
    }
}
