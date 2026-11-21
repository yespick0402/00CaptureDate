import Foundation

struct CaptureStamp: Equatable, Codable, Hashable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int

    static func parse(_ raw: String) -> CaptureStamp? {
        // Keep the camera's wall-clock date; never silently shift it using the host time zone.
        let regex = try! NSRegularExpression(pattern: #"^\s*(\d{4})[:\-](\d{1,2})[:\-](\d{1,2})[T ](\d{1,2}):(\d{1,2}):(\d{1,2})"#)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let hit = regex.firstMatch(in: raw, range: range) else { return nil }
        let nums = (1...6).compactMap { i -> Int? in
            guard let r = Range(hit.range(at: i), in: raw) else { return nil }
            return Int(raw[r])
        }
        guard nums.count == 6 else { return nil }
        let v = CaptureStamp(year: nums[0], month: nums[1], day: nums[2], hour: nums[3], minute: nums[4], second: nums[5])
        guard v.year >= 1900, v.year <= 2200, (1...12).contains(v.month),
              (1...31).contains(v.day), (0...23).contains(v.hour),
              (0...59).contains(v.minute), (0...60).contains(v.second) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var dc = DateComponents()
        dc.year = v.year; dc.month = v.month; dc.day = v.day
        dc.hour = v.hour; dc.minute = v.minute; dc.second = min(v.second, 59)
        guard let d = cal.date(from: dc) else { return nil }
        let round = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        guard round.year == v.year, round.month == v.month, round.day == v.day,
              round.hour == v.hour, round.minute == v.minute else { return nil }
        return v
    }

    var compactDate: String { String(format: "%04d%02d%02d", year, month, day) }
    var compactTime: String { String(format: "%02d%02d%02d", hour, minute, second) }
    var formatted: String {
        String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }
    var comparable: Int64 { Int64(year) * 10_000_000_000 + Int64(month) * 100_000_000 + Int64(day) * 1_000_000 + Int64(hour) * 10_000 + Int64(minute) * 100 + Int64(second) }
}

enum DateConfidence: String, Codable {
    case high = "높음"
    case review = "확인 필요"
    case missing = "없음"
}

struct CaptureEvidence: Codable {
    var stamp: CaptureStamp?
    var confidence: DateConfidence
    var source: String
    var details: String
    static let missing = CaptureEvidence(stamp: nil, confidence: .missing, source: "촬영일시 없음", details: "파일 생성일·수정일로 추정하지 않습니다")
}

enum NamePattern {
    static let defaultValue = "{YYYYMMDD}_{hhmmss}_{Originalname}"
    static let validTokens = ["YYYYMMDD", "hhmmss", "YYYY", "MM", "DD", "hh", "mm", "ss", "Originalname", "filename", "ext", "SEQ"]

    static func render(_ format: String, stamp: CaptureStamp, originalURL: URL, ordinal: Int) throws -> String {
        let base = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        let values: [String: String] = [
            "YYYYMMDD": stamp.compactDate, "hhmmss": stamp.compactTime,
            "YYYY": String(format: "%04d", stamp.year), "MM": String(format: "%02d", stamp.month),
            "DD": String(format: "%02d", stamp.day), "hh": String(format: "%02d", stamp.hour),
            "mm": String(format: "%02d", stamp.minute), "ss": String(format: "%02d", stamp.second),
            "Originalname": base, "filename": base, "ext": ext,
            "SEQ": String(format: "%04d", ordinal)
        ]
        let tokenRE = try! NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
        var out = format
        let ns = format as NSString
        let matches = tokenRE.matches(in: format, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let token = ns.substring(with: match.range(at: 1))
            guard let value = values[token] else { throw RuleError.invalidToken(token) }
            if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: value) }
        }
        if out.contains("{") || out.contains("}") { throw RuleError.invalidToken("중괄호") }
        // All pattern tokens are filename components. Extension is always preserved.
        out = out.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out != ".", out != "..", !out.hasPrefix("."), out.utf8.count <= 220 else {
            throw RuleError.invalidName
        }
        let explicitExtension = format.hasSuffix(".{ext}")
        return ext.isEmpty || explicitExtension ? out : out + "." + ext
    }

    enum RuleError: Error, LocalizedError {
        case invalidToken(String)
        case invalidName
        var errorDescription: String? {
            switch self {
            case .invalidToken(let s): return "지원하지 않는 파일명 토큰: \(s)"
            case .invalidName: return "파일명이 비어 있거나 너무 깁니다 (최대 220바이트)"
            }
        }
    }
}
