// HuggingFaceDownloader.swift
// Downloads model files from HuggingFace Hub

import Foundation
import MLXLMCommon
import os.log

private let logger = Logger(subsystem: "com.memory", category: "HuggingFaceDownloader")

/// Downloads model snapshots from HuggingFace Hub using the REST API.
///
/// Caches downloaded files in `~/Library/Caches/huggingface/hub/`.
/// Subsequent requests for the same model and revision return the cached directory.
struct HuggingFaceDownloader: Downloader {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let rev = revision ?? "main"
        let cacheDir = Self.cacheDirectory(for: id, revision: rev)

        // Return cached if exists and not forcing latest
        if !useLatest, FileManager.default.fileExists(atPath: cacheDir.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
            if !contents.isEmpty {
                logger.debug("Cache hit for \(id) at \(cacheDir.path)")
                return cacheDir
            }
        }

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // List files in the repository
        let files = try await listFiles(repoID: id, revision: rev)
        let matchedFiles = files.filter { name in
            patterns.contains { pattern in Self.matchGlob(pattern: pattern, string: name) }
        }

        logger.info("Downloading \(matchedFiles.count) files for \(id)")

        let progress = Progress(totalUnitCount: Int64(matchedFiles.count))

        for fileName in matchedFiles {
            let localURL = cacheDir.appendingPathComponent(fileName)

            // Skip already downloaded files unless forcing latest
            if !useLatest, FileManager.default.fileExists(atPath: localURL.path) {
                progress.completedUnitCount += 1
                progressHandler(progress)
                continue
            }

            // Create subdirectories if needed
            let parentDir = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let downloadURL = URL(string: "https://huggingface.co/\(id)/resolve/\(rev)/\(fileName)")!
            let (data, response) = try await session.data(from: downloadURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw HuggingFaceDownloaderError.downloadFailed(fileName, statusCode)
            }

            try data.write(to: localURL)
            progress.completedUnitCount += 1
            progressHandler(progress)
            logger.debug("Downloaded \(fileName) (\(data.count) bytes)")
        }

        return cacheDir
    }

    // MARK: - File Listing

    private func listFiles(repoID: String, revision: String) async throws -> [String] {
        let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/\(revision)")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw HuggingFaceDownloaderError.listFailed(repoID, statusCode)
        }

        let entries = try JSONDecoder().decode([FileEntry].self, from: data)
        return entries.compactMap { $0.type == "file" ? $0.rfilename : nil }
    }

    // MARK: - Cache

    private static func cacheDirectory(for repoID: String, revision: String) -> URL {
        let sanitizedID = repoID.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/hub/models--\(sanitizedID)/snapshots/\(revision)")
    }

    // MARK: - Glob Matching

    /// Simple glob matching: supports only `*.ext` patterns.
    private static func matchGlob(pattern: String, string: String) -> Bool {
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return string.hasSuffix(suffix)
        }
        return pattern == string
    }
}

// MARK: - Types

private struct FileEntry: Decodable {
    let type: String
    let rfilename: String
}

enum HuggingFaceDownloaderError: LocalizedError {
    case listFailed(String, Int)
    case downloadFailed(String, Int)

    var errorDescription: String? {
        switch self {
        case .listFailed(let repoID, let status):
            return "Failed to list files for '\(repoID)' (HTTP \(status))"
        case .downloadFailed(let fileName, let status):
            return "Failed to download '\(fileName)' (HTTP \(status))"
        }
    }
}
