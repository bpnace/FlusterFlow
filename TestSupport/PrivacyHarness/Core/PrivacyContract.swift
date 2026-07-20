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
    private let maximumFileSize: Int

    public init(maximumFiles: Int = 5_000, maximumFileSize: Int = 8 * 1_024 * 1_024) {
        self.maximumFiles = maximumFiles
        self.maximumFileSize = maximumFileSize
    }

    public func scan(canary: String, roots: [Root]) throws -> [PrivacyLeak] {
        guard !canary.isEmpty else { return [] }
        let needle = Data(canary.utf8)
        var leaks: [PrivacyLeak] = []
        var visited = 0

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
                guard size <= maximumFileSize else {
                    throw CanaryScanError.fileSizeLimitExceeded(rootLabel: root.label)
                }
                let data: Data
                do {
                    data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                } catch {
                    throw CanaryScanError.entryUnreadable(rootLabel: root.label)
                }
                guard data.range(of: needle) != nil else { continue }
                leaks.append(PrivacyLeak(kind: root.kind, location: root.label))
            }
            if traversalFailed {
                throw CanaryScanError.entryUnreadable(rootLabel: root.label)
            }
        }

        return leaks
    }
}
