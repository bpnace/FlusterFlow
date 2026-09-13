import Foundation

public enum PrivacyLeakKind: String, Codable, Equatable, Hashable, Sendable {
    case networkSocket
    case temporaryFile
    case logFile
    case unifiedLog
    case diagnosticFile
    case cacheFile
    case crashReport
    case childOutput
    case pasteboard
}

public struct PrivacyLeak: Codable, Equatable, Hashable, Sendable {
    public let kind: PrivacyLeakKind
    public let location: String

    public init(kind: PrivacyLeakKind, location: String) {
        self.kind = kind
        self.location = location
    }
}

public struct PrivacyHarnessReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let harnessId: String
    public let status: String
    public let childExitCode: Int32
    public let networkSampleCount: Int
    public let observedProcessCount: Int
    public let canaryClassCount: Int
    public let unifiedLogScanned: Bool
    public let pasteboardChanged: Bool
    public let leakCount: Int
    public let leaks: [PrivacyLeak]
    public let limitations: [String]

    public init(
        status: String,
        childExitCode: Int32,
        networkSampleCount: Int,
        observedProcessCount: Int,
        canaryClassCount: Int,
        unifiedLogScanned: Bool,
        pasteboardChanged: Bool,
        leaks: [PrivacyLeak],
        limitations: [String]
    ) {
        self.schemaVersion = 1
        self.harnessId = "E-PRIVACY-HARNESS"
        self.status = status
        self.childExitCode = childExitCode
        self.networkSampleCount = networkSampleCount
        self.observedProcessCount = observedProcessCount
        self.canaryClassCount = canaryClassCount
        self.unifiedLogScanned = unifiedLogScanned
        self.pasteboardChanged = pasteboardChanged
        self.leakCount = leaks.count
        self.leaks = leaks
        self.limitations = limitations
    }
}

public struct SocketObservationParser: Sendable {
    public init() {}

    public func socketDescriptions(fromLSOFOutput output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map(String.init)
            .filter { line in
                line.contains(" TCP ")
                    || line.contains(" UDP ")
                    || line.contains(" IPv4 ")
                    || line.contains(" IPv6 ")
            }
            .map(Self.redactedSocketDescription)
    }

    private static func redactedSocketDescription(_ line: String) -> String {
        let columns = line.split(whereSeparator: \.isWhitespace)
        guard columns.count >= 8 else { return "network socket" }
        let command = columns[0]
        let descriptor = columns[3]
        let protocolName = columns.contains("TCP") ? "TCP" : (columns.contains("UDP") ? "UDP" : "IP")
        return "\(command) fd=\(descriptor) protocol=\(protocolName)"
    }
}

public enum CanaryScanError: Error, Equatable, Sendable {
    case rootIsSymbolicLink(rootLabel: String)
    case rootUnreadable(rootLabel: String)
    case entryIsSymbolicLink(rootLabel: String)
    case entryUnreadable(rootLabel: String)
    case fileLimitExceeded(rootLabel: String)
    case fileSizeLimitExceeded(rootLabel: String)
    case totalByteLimitExceeded(rootLabel: String)

    public var contentFreeLimitation: String {
        switch self {
        case .rootIsSymbolicLink(let label):
            "Canary scan incomplete: symbolic-link root at \(label)."
        case .rootUnreadable(let label):
            "Canary scan incomplete: unreadable root at \(label)."
        case .entryIsSymbolicLink(let label):
            "Canary scan incomplete: symbolic-link entry at \(label)."
        case .entryUnreadable(let label):
            "Canary scan incomplete: unreadable entry at \(label)."
        case .fileLimitExceeded(let label):
            "Canary scan incomplete: file limit exceeded at \(label)."
        case .fileSizeLimitExceeded(let label):
            "Canary scan incomplete: file-size limit exceeded at \(label)."
        case .totalByteLimitExceeded(let label):
            "Canary scan incomplete: total-byte limit exceeded at \(label)."
        }
    }
}

public struct CanaryLeakScanner: Sendable {
    public struct Root: Equatable, Sendable {
        public let url: URL
        public let kind: PrivacyLeakKind
        public let label: String

        public init(url: URL, kind: PrivacyLeakKind, label: String) {
            self.url = url
            self.kind = kind
            self.label = label
        }
    }

    private let maximumFiles: Int
    private let maximumFileSize: Int64
    private let maximumTotalBytes: Int64
    private let chunkSize: Int

    public init(
        maximumFiles: Int = 5_000,
        maximumFileSize: Int64 = 512 * 1_024 * 1_024,
        maximumTotalBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
        chunkSize: Int = 1 * 1_024 * 1_024
    ) {
        precondition(maximumFiles > 0)
        precondition(maximumFileSize > 0)
        precondition(maximumTotalBytes > 0)
        precondition(chunkSize > 0)
        self.maximumFiles = maximumFiles
        self.maximumFileSize = maximumFileSize
        self.maximumTotalBytes = maximumTotalBytes
        self.chunkSize = chunkSize
    }

    public func scan(canary: String, roots: [Root]) throws -> [PrivacyLeak] {
        try scan(canaries: [canary], roots: roots)
    }

    public func scan(canaries: some Sequence<String>, roots: [Root]) throws -> [PrivacyLeak] {
        let needles = Array(Set(canaries.filter { !$0.isEmpty })).map { Data($0.utf8) }
        guard !needles.isEmpty else { return [] }
        var leaks: [PrivacyLeak] = []
        var visited = 0
        var totalBytes: Int64 = 0

        for root in roots {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
            var rootIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.url.path,
                isDirectory: &rootIsDirectory
            ) else {
                continue
            }
            guard rootIsDirectory.boolValue else {
                throw CanaryScanError.rootUnreadable(rootLabel: root.label)
            }
            let rootValues: URLResourceValues
            do {
                rootValues = try root.url.resourceValues(forKeys: [.isSymbolicLinkKey])
            } catch {
                throw CanaryScanError.rootUnreadable(rootLabel: root.label)
            }
            guard rootValues.isSymbolicLink != true else {
                throw CanaryScanError.rootIsSymbolicLink(rootLabel: root.label)
            }
            var traversalFailed = false
            guard let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in
                    traversalFailed = true
                    return false
                }
            ) else {
                throw CanaryScanError.rootUnreadable(rootLabel: root.label)
            }

            while let fileURL = enumerator.nextObject() as? URL {
                guard visited < maximumFiles else {
                    throw CanaryScanError.fileLimitExceeded(rootLabel: root.label)
                }
                visited += 1
                let values: URLResourceValues
                do {
                    values = try fileURL.resourceValues(forKeys: Set(keys))
                } catch {
                    throw CanaryScanError.entryUnreadable(rootLabel: root.label)
                }
                guard values.isSymbolicLink != true else {
                    throw CanaryScanError.entryIsSymbolicLink(rootLabel: root.label)
                }
                guard values.isRegularFile == true else {
                    continue
                }
                guard let size = values.fileSize else {
                    throw CanaryScanError.entryUnreadable(rootLabel: root.label)
                }
                let fileSize = Int64(size)
                guard fileSize <= maximumFileSize else {
                    throw CanaryScanError.fileSizeLimitExceeded(rootLabel: root.label)
                }
                let (nextTotal, overflowed) = totalBytes.addingReportingOverflow(fileSize)
                guard !overflowed, nextTotal <= maximumTotalBytes else {
                    throw CanaryScanError.totalByteLimitExceeded(rootLabel: root.label)
                }
                totalBytes = nextTotal
                guard try fileContainsAnyNeedle(
                    at: fileURL,
                    fileSize: size,
                    needles: needles,
                    rootLabel: root.label
                ) else { continue }
                leaks.append(PrivacyLeak(kind: root.kind, location: root.label))
            }
            if traversalFailed {
                throw CanaryScanError.entryUnreadable(rootLabel: root.label)
            }
        }

        return leaks
    }

    private func fileContainsAnyNeedle(
        at url: URL,
        fileSize: Int,
        needles: [Data],
        rootLabel: String
    ) throws -> Bool {
        if fileSize <= chunkSize {
            do {
                let data = try Data(contentsOf: url)
                return needles.contains { data.range(of: $0) != nil }
            } catch {
                throw CanaryScanError.entryUnreadable(rootLabel: rootLabel)
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CanaryScanError.entryUnreadable(rootLabel: rootLabel)
        }
        defer { try? handle.close() }

        let overlapCount = max(needles.map(\.count).max() ?? 1, 1) - 1
        var overlap = Data()
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                var searchable = overlap
                searchable.append(chunk)
                if needles.contains(where: { searchable.range(of: $0) != nil }) {
                    return true
                }
                overlap = Data(searchable.suffix(overlapCount))
            }
        } catch {
            throw CanaryScanError.entryUnreadable(rootLabel: rootLabel)
        }
        return false
    }
}
