import Foundation

public enum BenchmarkJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([0x0A])
    }

    public static func write<T: Encodable>(_ value: T, to url: URL?) throws {
        let data = try encode(value)
        if let url {
            try data.write(to: url, options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}
