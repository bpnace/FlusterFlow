@preconcurrency import AppKit
import Darwin
import Foundation
import PrivacyHarnessCore

@main
enum PrivacyHarnessMain {
    static func main() {
        do {
            if CommandLine.arguments.dropFirst().first == "--socket-fixture" {
                try LoopbackSocketFixture.run()
                return
            }
            if CommandLine.arguments.dropFirst().first == "--canary-leak-fixture" {
                try CanaryLeakFixture.run()
                return
            }

            let configuration = try PrivacyHarnessConfiguration(arguments: Array(CommandLine.arguments.dropFirst()))
            let report = try DynamicPrivacyRunner(configuration: configuration).run()
            try writeJSON(report)
            if report.status != "passed" {
                exit(1)
            }
        } catch {
            let report = PrivacyHarnessReport(
                status: "failed",
                childExitCode: -1,
                networkSampleCount: 0,
                observedProcessCount: 0,
                canaryClassCount: 0,
                unifiedLogScanned: false,
                pasteboardChanged: false,
                leaks: [],
                limitations: ["Harness setup failed: \(contentFreeFailureCode(error))."]
            )
            try? writeJSON(report)
            exit(2)
        }
    }
}

private struct PrivacyHarnessConfiguration {
    let command: String
    let arguments: [String]
    let scanURLs: [URL]
    let pollIntervalMicroseconds: useconds_t
    let allowPasteboardChange: Bool

    init(arguments: [String]) throws {
        guard let separator = arguments.firstIndex(of: "--"),
              arguments.indices.contains(separator + 1) else {
            throw PrivacyHarnessError.missingCommand
        }

        var scanURLs: [URL] = []
        var pollMilliseconds: UInt32 = 25
        var allowPasteboardChange = false
        var index = arguments.startIndex
        while index < separator {
            switch arguments[index] {
            case "--scan":
                guard index + 1 < separator else { throw PrivacyHarnessError.invalidArguments }
                scanURLs.append(URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
                index += 2
            case "--poll-ms":
                guard index + 1 < separator,
                      let value = UInt32(arguments[index + 1]),
                      (10...1_000).contains(value) else {
                    throw PrivacyHarnessError.invalidArguments
                }
                pollMilliseconds = value
                index += 2
            case "--allow-pasteboard-change":
                allowPasteboardChange = true
                index += 1
            default:
                throw PrivacyHarnessError.invalidArguments
            }
        }

        self.command = arguments[separator + 1]
        self.arguments = Array(arguments.dropFirst(separator + 2))
        self.scanURLs = scanURLs
        self.pollIntervalMicroseconds = pollMilliseconds * 1_000
        self.allowPasteboardChange = allowPasteboardChange
    }
}

private struct DynamicPrivacyRunner {
    let configuration: PrivacyHarnessConfiguration

    func run() throws -> PrivacyHarnessReport {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: "/usr/sbin/lsof"),
              fileManager.isExecutableFile(atPath: "/usr/bin/pgrep"),
              fileManager.isExecutableFile(atPath: "/usr/bin/log") else {
            throw PrivacyHarnessError.observerUnavailable
        }
        let runRoot = fileManager.temporaryDirectory
            .appendingPathComponent("FlusterFlow-PrivacyHarness-\(UUID().uuidString)", isDirectory: true)
        let childTemporaryRoot = runRoot.appendingPathComponent("ChildTemporary", isDirectory: true)
        let childOutputRoot = runRoot.appendingPathComponent("ChildOutput", isDirectory: true)
        try fileManager.createDirectory(at: childTemporaryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: childOutputRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: runRoot) }

        let stdoutURL = childOutputRoot.appendingPathComponent("stdout")
        let stderrURL = childOutputRoot.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let canaries = [
            "TRANSCRIPT": "wf-transcript-\(UUID().uuidString)",
            "CONTEXT": "wf-context-\(UUID().uuidString)",
            "WINDOW_TITLE": "wf-window-\(UUID().uuidString)",
            "PATH": "wf-path-\(UUID().uuidString)",
            "KEY": "wf-key-\(UUID().uuidString)"
        ]
        let pasteboard = NSPasteboard.general
        let pasteboardBefore = pasteboard.changeCount

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.command)
        process.arguments = configuration.arguments
        var environment = ProcessInfo.processInfo.environment
        for (name, value) in canaries {
            environment["WHISPERFLOW_PRIVACY_CANARY_\(name)"] = value
        }
        environment["TMPDIR"] = childTemporaryRoot.path + "/"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let rootPID = process.processIdentifier
        var observedPIDs: Set<Int32> = [rootPID]
        var networkLeaks: [PrivacyLeak] = []
        var networkSampleCount = 0

        repeat {
            let currentPIDs = try processTree(root: rootPID)
            observedPIDs.formUnion(currentPIDs)
            for pid in currentPIDs {
                networkSampleCount += 1
                let descriptions = try openSocketDescriptions(processIdentifier: pid)
                for description in descriptions where !networkLeaks.contains(where: { $0.location == description }) {
                    networkLeaks.append(PrivacyLeak(kind: .networkSocket, location: description))
                }
            }
            if process.isRunning {
                usleep(configuration.pollIntervalMicroseconds)
            }
        } while process.isRunning
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()

        let roots = scanRoots(
            childTemporaryRoot: childTemporaryRoot,
            childOutputRoot: childOutputRoot,
            additional: configuration.scanURLs
        )
        var leaks = networkLeaks
        var scanError: CanaryScanError?
        for canary in canaries.values where scanError == nil {
            do {
                leaks.append(contentsOf: try CanaryLeakScanner().scan(canary: canary, roots: roots))
            } catch let error as CanaryScanError {
                scanError = error
            }
        }

        let unifiedLogData = try copyUnifiedLog(processIdentifier: rootPID)
        for canary in canaries.values where unifiedLogData.range(of: Data(canary.utf8)) != nil {
            leaks.append(PrivacyLeak(kind: .unifiedLog, location: "unified-log"))
        }

        let pasteboardChanged = pasteboard.changeCount != pasteboardBefore
        if canaries.values.contains(where: { pasteboardContains(canary: $0, pasteboard: pasteboard) }) {
            leaks.append(PrivacyLeak(kind: .pasteboard, location: "general-pasteboard-canary"))
        } else if pasteboardChanged && !configuration.allowPasteboardChange {
            leaks.append(PrivacyLeak(kind: .pasteboard, location: "general-pasteboard-change-count"))
        }

        leaks = Array(Set(leaks)).sorted {
            ($0.kind.rawValue, $0.location) < ($1.kind.rawValue, $1.location)
        }
        let failed = process.terminationStatus != 0 || !leaks.isEmpty
        let status = failed ? "failed" : (scanError == nil ? "passed" : "inconclusive")
        var limitations = [
            "Socket observation polls lsof and can miss connections shorter than the configured polling interval.",
            "The canary scanner proves absence only in Unified Log, isolated TMPDIR, captured child output, declared app log/cache/diagnostic/crash roots, and explicit --scan roots.",
            "Provider, model, and live API traffic are intentionally outside this local-only smoke run."
        ]
        if let scanError {
            limitations.append(scanError.contentFreeLimitation)
        }
        return PrivacyHarnessReport(
            status: status,
            childExitCode: process.terminationStatus,
            networkSampleCount: networkSampleCount,
            observedProcessCount: observedPIDs.count,
            canaryClassCount: canaries.count,
            unifiedLogScanned: true,
            pasteboardChanged: pasteboardChanged,
            leaks: leaks,
            limitations: limitations
        )
    }

    private func processTree(root: Int32) throws -> Set<Int32> {
        var result: Set<Int32> = [root]
        var pending: [Int32] = [root]
        while let parent = pending.popLast() {
            for child in try childProcessIdentifiers(parent: parent) where result.insert(child).inserted {
                pending.append(child)
            }
        }
        return result
    }

    private func childProcessIdentifiers(parent: Int32) throws -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(parent)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 || process.terminationStatus == 1,
              let value = String(data: data, encoding: .utf8) else {
            throw PrivacyHarnessError.observerUnavailable
        }
        return value.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }

    private func openSocketDescriptions(processIdentifier: Int32) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(processIdentifier), "-i"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 || process.terminationStatus == 1,
              let value = String(data: data, encoding: .utf8) else {
            throw PrivacyHarnessError.observerUnavailable
        }
        return SocketObservationParser().socketDescriptions(fromLSOFOutput: value)
    }

    private func copyUnifiedLog(processIdentifier: Int32) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--style", "json",
            "--last", "2m",
            "--predicate", "processIdentifier == \(processIdentifier)",
            "--info",
            "--debug",
            "--no-signpost"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw PrivacyHarnessError.unifiedLogUnavailable
        }
        return data
    }

    private func scanRoots(
        childTemporaryRoot: URL,
        childOutputRoot: URL,
        additional: [URL]
    ) -> [CanaryLeakScanner.Root] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            CanaryLeakScanner.Root(url: childTemporaryRoot, kind: .temporaryFile, label: "isolated-child-tmp"),
            CanaryLeakScanner.Root(url: childOutputRoot, kind: .childOutput, label: "captured-child-output"),
            CanaryLeakScanner.Root(
                url: home.appendingPathComponent("Library/Logs/FlusterFlow", isDirectory: true),
                kind: .logFile,
                label: "flusterflow-logs"
            ),
            CanaryLeakScanner.Root(
                url: home.appendingPathComponent("Library/Application Support/FlusterFlow/Diagnostics", isDirectory: true),
                kind: .diagnosticFile,
                label: "flusterflow-diagnostics"
            ),
            CanaryLeakScanner.Root(
                url: home.appendingPathComponent("Library/Caches/FlusterFlow", isDirectory: true),
                kind: .cacheFile,
                label: "flusterflow-caches"
            ),
            CanaryLeakScanner.Root(
                url: home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
                kind: .crashReport,
                label: "diagnostic-reports"
            )
        ]
        roots.append(contentsOf: additional.enumerated().map { index, url in
            CanaryLeakScanner.Root(url: url, kind: .diagnosticFile, label: "explicit-scan-\(index)")
        })
        return roots
    }

    private func pasteboardContains(canary: String, pasteboard: NSPasteboard) -> Bool {
        pasteboard.pasteboardItems?.contains { item in
            item.types.contains { type in
                item.string(forType: type)?.contains(canary) == true
            }
        } == true
    }
}

private enum LoopbackSocketFixture {
    static func run() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw PrivacyHarnessError.socketFixture }
        defer { Darwin.close(listener) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(listener, 1) == 0 else {
            throw PrivacyHarnessError.socketFixture
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getsockname(listener, withUnsafeMutablePointer(to: &address, {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self)
        }), &length) == 0 else {
            throw PrivacyHarnessError.socketFixture
        }

        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { throw PrivacyHarnessError.socketFixture }
        defer { Darwin.close(client) }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw PrivacyHarnessError.socketFixture }

        var peer = sockaddr()
        var peerLength = socklen_t(MemoryLayout<sockaddr>.size)
        let accepted = accept(listener, &peer, &peerLength)
        guard accepted >= 0 else { throw PrivacyHarnessError.socketFixture }
        defer { Darwin.close(accepted) }
        Thread.sleep(forTimeInterval: 0.8)
    }
}

private enum CanaryLeakFixture {
    static func run() throws {
        guard let canary = ProcessInfo.processInfo.environment["WHISPERFLOW_PRIVACY_CANARY_TRANSCRIPT"],
              let temporaryRoot = ProcessInfo.processInfo.environment["TMPDIR"] else {
            throw PrivacyHarnessError.canaryFixture
        }
        let url = URL(fileURLWithPath: temporaryRoot, isDirectory: true)
            .appendingPathComponent("intentional-canary-leak")
        try Data(canary.utf8).write(to: url, options: .atomic)
        Thread.sleep(forTimeInterval: 0.4)
    }
}

private enum PrivacyHarnessError: String, Error {
    case missingCommand = "missing-command"
    case invalidArguments = "invalid-arguments"
    case socketFixture = "socket-fixture"
    case canaryFixture = "canary-fixture"
    case observerUnavailable = "observer-unavailable"
    case unifiedLogUnavailable = "unified-log-unavailable"
}

private func contentFreeFailureCode(_ error: any Error) -> String {
    (error as? PrivacyHarnessError)?.rawValue ?? "runtime-operation"
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}
