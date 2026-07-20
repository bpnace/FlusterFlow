import Foundation

enum TestResourceLoader {
    static func url(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(".."),
              let resourceRoot = resourceBundle.resourceURL else {
            throw TestResourceError.invalidPath
        }
        let url = resourceRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(resourceRoot.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path) else {
            throw TestResourceError.missing(relativePath)
        }
        return url
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath), options: [.mappedIfSafe])
    }

    static func string(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle(for: TestBundleToken.self)
        #endif
    }
}

private final class TestBundleToken: NSObject {}

private enum TestResourceError: Error, Equatable {
    case invalidPath
    case missing(String)
}
