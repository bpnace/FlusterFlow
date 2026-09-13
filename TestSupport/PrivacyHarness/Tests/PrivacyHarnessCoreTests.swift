import Foundation
import XCTest
@testable import PrivacyHarnessCore

final class PrivacyHarnessCoreTests: XCTestCase {
    func testLSOFParserDetectsAndRedactsNetworkSockets() {
        let fixture = """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        helper 900 test 7u IPv4 0x0 0t0 TCP 127.0.0.1:41000->127.0.0.1:41001 (ESTABLISHED)
        helper 900 test 8u REG 1,1 0 1 /tmp/file
        """

        let descriptions = SocketObservationParser().socketDescriptions(fromLSOFOutput: fixture)

        XCTAssertEqual(descriptions, ["helper fd=7u protocol=TCP"])
        XCTAssertFalse(descriptions[0].contains("127.0.0.1"))
    }

    func testCanaryScannerReportsLabelWithoutSecretOrFilePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyHarnessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = "synthetic-private-canary"
        try Data("prefix \(canary) suffix".utf8).write(to: root.appendingPathComponent("diagnostic.txt"))

        let leaks = try CanaryLeakScanner().scan(
            canary: canary,
            roots: [.init(url: root, kind: .diagnosticFile, label: "test-diagnostics")]
        )

        XCTAssertEqual(leaks, [PrivacyLeak(kind: .diagnosticFile, location: "test-diagnostics")])
        XCTAssertFalse(leaks[0].location.contains(canary))
        XCTAssertFalse(leaks[0].location.contains(root.path))
    }

    func testCanaryScannerPassesForContentFreeDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyHarnessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("count=4,p50=120,p95=180".utf8).write(to: root.appendingPathComponent("diagnostic.txt"))

        XCTAssertTrue(
            try CanaryLeakScanner().scan(
                canary: "synthetic-private-canary",
                roots: [.init(url: root, kind: .diagnosticFile, label: "test-diagnostics")]
            ).isEmpty
        )
    }

    func testCanaryScannerScansHiddenPackageContents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent(".Synthetic.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let canary = "synthetic-private-canary"
        try Data(canary.utf8).write(to: package.appendingPathComponent(".diagnostic"))

        let leaks = try CanaryLeakScanner().scan(
            canary: canary,
            roots: [.init(url: root, kind: .diagnosticFile, label: "test-diagnostics")]
        )

        XCTAssertEqual(leaks, [PrivacyLeak(kind: .diagnosticFile, location: "test-diagnostics")])
    }

    func testCanaryScannerFailsClosedWhenFileSizeLimitWouldSkipContent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("synthetic-private-canary".utf8).write(to: root.appendingPathComponent("large"))

        XCTAssertThrowsError(
            try CanaryLeakScanner(maximumFiles: 10, maximumFileSize: 4).scan(
                canary: "synthetic-private-canary",
                roots: [.init(url: root, kind: .diagnosticFile, label: "test-diagnostics")]
            )
        ) { error in
            XCTAssertEqual(
                error as? CanaryScanError,
                .fileSizeLimitExceeded(rootLabel: "test-diagnostics")
            )
        }
    }

    func testCanaryScannerFindsCanaryInLargeFileWithoutLoadingItWhole() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = "synthetic-private-canary"
        var contents = Data(repeating: 0x61, count: 160)
        contents.append(Data(canary.utf8))
        contents.append(Data(repeating: 0x62, count: 160))
        try contents.write(to: root.appendingPathComponent("large"))

        let leaks = try CanaryLeakScanner(chunkSize: 32).scan(
            canaries: ["another-canary", canary, "third-canary"],
            roots: [.init(url: root, kind: .cacheFile, label: "test-cache")]
        )

        XCTAssertEqual(leaks, [PrivacyLeak(kind: .cacheFile, location: "test-cache")])
    }

    func testCanaryScannerFindsCanaryAcrossChunkBoundary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = "boundary-canary"
        var contents = Data(repeating: 0x61, count: 29)
        contents.append(Data(canary.utf8))
        contents.append(Data(repeating: 0x62, count: 32))
        try contents.write(to: root.appendingPathComponent("chunked"))

        let leaks = try CanaryLeakScanner(chunkSize: 32).scan(
            canaries: [canary],
            roots: [.init(url: root, kind: .diagnosticFile, label: "test-diagnostics")]
        )

        XCTAssertEqual(leaks, [PrivacyLeak(kind: .diagnosticFile, location: "test-diagnostics")])
    }

    func testCanaryScannerFailsClosedWhenTotalByteLimitWouldTruncateScan() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x61, count: 6).write(to: root.appendingPathComponent("first"))
        try Data(repeating: 0x62, count: 6).write(to: root.appendingPathComponent("second"))

        XCTAssertThrowsError(
            try CanaryLeakScanner(maximumTotalBytes: 10).scan(
                canaries: ["synthetic-private-canary"],
                roots: [.init(url: root, kind: .diagnosticFile, label: "test-diagnostics")]
            )
        ) { error in
            XCTAssertEqual(
                error as? CanaryScanError,
                .totalByteLimitExceeded(rootLabel: "test-diagnostics")
            )
        }
    }

    func testCanaryScannerFailsClosedWhenFileLimitWouldTruncateScan() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("content-free".utf8).write(to: root.appendingPathComponent("first"))
        try Data("synthetic-private-canary".utf8).write(to: root.appendingPathComponent("second"))

        XCTAssertThrowsError(
            try CanaryLeakScanner(maximumFiles: 1).scan(
                canary: "synthetic-private-canary",
                roots: [.init(url: root, kind: .diagnosticFile, label: "test-diagnostics")]
            )
        ) { error in
            XCTAssertEqual(
                error as? CanaryScanError,
                .fileLimitExceeded(rootLabel: "test-diagnostics")
            )
        }
    }

    func testCanaryScannerFailsClosedForUnreadableSubdirectory() throws {
        let root = try temporaryDirectory()
        let restricted = root.appendingPathComponent("restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        try Data("synthetic-private-canary".utf8).write(
            to: restricted.appendingPathComponent("diagnostic")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0)],
            ofItemAtPath: restricted.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: restricted.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertThrowsError(
            try CanaryLeakScanner().scan(
                canary: "synthetic-private-canary",
                roots: [.init(url: root, kind: .diagnosticFile, label: "test-diagnostics")]
            )
        ) { error in
            XCTAssertEqual(
                error as? CanaryScanError,
                .entryUnreadable(rootLabel: "test-diagnostics")
            )
        }
    }

    func testReportIsMachineReadableAndContentFree() throws {
        let report = PrivacyHarnessReport(
            status: "passed",
            childExitCode: 0,
            networkSampleCount: 4,
            observedProcessCount: 1,
            canaryClassCount: 5,
            unifiedLogScanned: true,
            pasteboardChanged: false,
            leaks: [],
            limitations: ["polling observer"]
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PrivacyHarnessReport.self, from: data)

        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.harnessId, "E-PRIVACY-HARNESS")
        XCTAssertEqual(decoded.leakCount, 0)
        XCTAssertEqual(decoded.canaryClassCount, 5)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyHarnessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
