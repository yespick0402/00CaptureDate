import Foundation

// A folder template creates only relative, date-based subdirectories.
// Literal quotes are optional: {YYYY}"년"/{MM}"월" behaves like {YYYY}년/{MM}월.
// Original filename tokens are intentionally not allowed in folders, to avoid
// unexpected per-file directory trees and ambiguous cross-file grouping.
enum FolderLayout: String, CaseIterable, Identifiable {
    case existing = "기존 / 지정 폴더"
    case captureDate = "촬영일자별 폴더"
    var id: String { rawValue }
}

enum FolderPattern {
    static let defaultValue = "{YYYY}년/{MM}월/{YYYY}.{MM}.{DD}_"
    private static let dateTokens = ["YYYYMMDD", "hhmmss", "YYYY", "MM", "DD", "hh", "mm", "ss"]

    static func render(_ template: String, stamp: CaptureStamp) throws -> String {
        // Split first: folder separator `/` is syntactic, never derived from a value.
        // Quote marks delimit literals, not path data; users may omit them.
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in template {
            if character == "\"" {
                quoted.toggle()
            } else if character == "/" {
                guard !quoted else { throw RuleError.unsafe("따옴표 안에는 /를 넣을 수 없습니다") }
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !quoted else { throw RuleError.unsafe("닫히지 않은 큰따옴표가 있습니다") }
        parts.append(current)
        guard (1...12).contains(parts.count) else { throw RuleError.unsafe("폴더 깊이는 1~12단계만 가능합니다") }

        let values: [String: String] = [
            "YYYYMMDD": stamp.compactDate, "hhmmss": stamp.compactTime,
            "YYYY": String(format: "%04d", stamp.year),
            "MM": String(format: "%02d", stamp.month), "DD": String(format: "%02d", stamp.day),
            "hh": String(format: "%02d", stamp.hour), "mm": String(format: "%02d", stamp.minute),
            "ss": String(format: "%02d", stamp.second)
        ]
        let matcher = try! NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
        var rendered: [String] = []
        for component in parts {
            var name = component
            let original = component as NSString
            for match in matcher.matches(in: component, range: NSRange(location: 0, length: original.length)).reversed() {
                let token = original.substring(with: match.range(at: 1))
                guard dateTokens.contains(token), let value = values[token] else {
                    throw RuleError.unsafe("지원하지 않는 폴더 토큰: {\(token)}")
                }
                guard let range = Range(match.range, in: name) else { throw RuleError.unsafe("폴더 양식을 해석하지 못했습니다") }
                name.replaceSubrange(range, with: value)
            }
            name = name.precomposedStringWithCanonicalMapping
            guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
                  name.utf8.count <= 240,
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  !name.contains("{"), !name.contains("}"),
                  !name.contains(":"), !name.contains("\\"),
                  !name.contains("/") && !name.contains("*") else {
                throw RuleError.unsafe("폴더명이 비었거나 안전하지 않습니다: \(name.prefix(50))")
            }
            rendered.append(name)
        }
        let result = rendered.joined(separator: "/")
        guard result.utf8.count <= 2048 else { throw RuleError.unsafe("폴더 경로가 너무 깁니다") }
        return result
    }

    enum RuleError: LocalizedError {
        case unsafe(String)
        var errorDescription: String? {
            switch self { case .unsafe(let reason): return "폴더 양식 오류: " + reason }
        }
    }
}
