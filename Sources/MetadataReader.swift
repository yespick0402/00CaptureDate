import Foundation

struct MediaInput {
    let url: URL
    let size: Int64
    let relativeFolder: String
    let modified: Date?
}

struct MediaEntry: Identifiable {
    let id: UUID
    let ordinal: Int
    let url: URL
    let size: Int64
    let relativeFolder: String
    let modified: Date?
    var evidence: CaptureEvidence
    var approved: Bool = false

    init(source: MediaInput, evidence: CaptureEvidence, ordinal: Int) {
        self.id = UUID()
        self.ordinal = ordinal
        self.url = source.url
        self.size = source.size
        self.relativeFolder = source.relativeFolder
        self.modified = source.modified
        self.evidence = evidence
    }

    var eligible: Bool {
        evidence.stamp != nil && (evidence.confidence == .high || approved)
    }
}

enum MediaInventory {
    static let photo: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff", "png", "dng", "arw", "cr2", "cr3", "nef", "nrw", "raf", "rw2", "orf", "pef", "srw", "3fr", "iiq", "mos", "raw", "webp", "avif"]
    static let movie: Set<String> = ["mov", "mp4", "m4v", "mts", "m2ts", "mxf", "avi", "mpg", "mpeg", "3gp", "insv"]
    static var supported: Set<String> { photo.union(movie) }

    static func discover(_ roots: [URL], cancelled: () -> Bool) -> [MediaInput] {
        let manager = FileManager.default
        var result: [MediaInput] = []
        var seen = Set<String>()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        func include(_ u: URL, relativeFolder: String) {
            if cancelled() { return }
            guard supported.contains(u.pathExtension.lowercased()) else { return }
            let path = u.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            guard let props = try? u.resourceValues(forKeys: keys),
                  props.isRegularFile == true, props.isSymbolicLink != true else { return }
            result.append(MediaInput(url: u, size: Int64(props.fileSize ?? 0), relativeFolder: relativeFolder, modified: props.contentModificationDate))
        }
        for root in roots {
            if cancelled() { break }
            let rv = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if rv?.isSymbolicLink == true { continue }
            if rv?.isDirectory == true {
                let base = root.standardizedFileURL.path
                let rootFolder = root.lastPathComponent
                guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
                for case let file as URL in enumerator {
                    if cancelled() { break }
                    guard file.path.hasPrefix(base + "/") else { continue }
                    let parent = file.deletingLastPathComponent().path
                    let relative = parent == base ? rootFolder : rootFolder + String(parent.dropFirst(base.count))
                    include(file, relativeFolder: relative)
                }
            } else {
                include(root, relativeFolder: "")
            }
        }
        return result.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}

final class MetadataReader {
    let toolURL: URL

    init(toolURL: URL) { self.toolURL = toolURL }

    // Single authoritative list: both one-shot and persistent transports use exactly
    // the same metadata flags. Never simplify this list for performance.
    static let exifArguments = ["-j", "-G1", "-a", "-s", "-api", "LargeFileSupport=1",
                                "-api", "QuickTimeUTC=0", "-charset", "filename=UTF8",
                                "-FileType", "-DateTimeOriginal", "-CreateDate", "-CreationDate",
                                "-DateCreated", "-OffsetTimeOriginal", "-ContentCreateDate",
                                "-MediaCreateDate", "-TrackCreateDate", "-TimeZone", "-DateTime"]

    func readBatch(_ inputs: [MediaInput]) -> [String: CaptureEvidence] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.currentDirectoryURL = toolURL.deletingLastPathComponent()
        // ExifTool runs read-only. Do not rely on Finder's creation or modification dates.
        p.arguments = [toolURL.path] + Self.exifArguments + inputs.map { $0.url.path }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile() // drain before wait to avoid pipe deadlock
            p.waitUntilExit()
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return Dictionary(uniqueKeysWithValues: inputs.map { ($0.url.path, CaptureEvidence(stamp: nil, confidence: .missing, source: "ExifTool 오류", details: "메타데이터 도구 실행 결과를 확인하세요")) })
            }
            var evidence: [String: CaptureEvidence] = [:]
            for row in rows {
                guard let path = row["SourceFile"] as? String else { continue }
                evidence[path] = interpret(row: row, file: URL(fileURLWithPath: path))
            }
            return evidence
        } catch {
            return Dictionary(uniqueKeysWithValues: inputs.map { ($0.url.path, CaptureEvidence(stamp: nil, confidence: .missing, source: "ExifTool 실행 불가", details: error.localizedDescription)) })
        }
    }

    func interpret(row: [String: Any], file: URL) -> CaptureEvidence {
        let isMovie = MediaInventory.movie.contains(file.pathExtension.lowercased())
        let pairs: [(key: String, value: String)] = row.compactMap { (k, v) in
            if let s = v as? String { return (key: k, value: s) }
            if let n = v as? NSNumber { return (key: k, value: n.stringValue) }
            return nil
        }.sorted { $0.key < $1.key }
        func matches(_ group: String, _ tag: String) -> [(key: String, value: String)] {
            pairs.filter { $0.key.lowercased().hasPrefix(group.lowercased() + ":") &&
                $0.key.split(separator: ":").last?.lowercased() == tag.lowercased() }
        }
        func anyTag(_ tag: String) -> [(key: String, value: String)] {
            pairs.filter { $0.key.split(separator: ":").last?.lowercased() == tag.lowercased() }
        }
        func candidate(_ list: [(key: String, value: String)], high: Bool, explanation: String) -> CaptureEvidence? {
            for info in list {
                if let date = CaptureStamp.parse(info.value) {
                    return CaptureEvidence(stamp: date, confidence: high ? .high : .review,
                                           source: info.key, details: explanation + " · 원본 값: " + info.value)
                }
            }
            return nil
        }
        func hasZone(_ s: String) -> Bool {
            s.range(of: #"[+-](?:0\d|1[0-4]):?[0-5]\d\s*$"#, options: .regularExpression) != nil
        }
        if !isMovie {
            // EXIF DateTimeOriginal is the camera's wall clock, even if no offset was recorded.
            let exif = matches("ExifIFD", "DateTimeOriginal") + matches("EXIF", "DateTimeOriginal")
            if var found = candidate(exif, high: true, explanation: "카메라 EXIF 원본 촬영일시") {
                if let xmp = candidate(anyTag("DateCreated"), high: false, explanation: "XMP"),
                   let other = xmp.stamp, let first = found.stamp,
                   first.compactDate != other.compactDate || first.compactTime != other.compactTime {
                    found.confidence = .review
                    found.details += " · XMP 날짜 불일치: " + other.formatted
                }
                return found
            }
            if let value = candidate(matches("MakerNotes", "DateTimeOriginal"), high: false, explanation: "제조사 기록 (확인 필요)") { return value }
            if let value = candidate(anyTag("DateTimeOriginal"), high: false, explanation: "EXIF 이외 촬영일시 (확인 필요)") { return value }
            if let value = candidate(anyTag("DateCreated"), high: false, explanation: "XMP 생성일 (확인 필요)") { return value }
            if let value = candidate(matches("ExifIFD", "CreateDate"), high: false, explanation: "디지털화 일시, 원본 촬영일시 아님") { return value }
            return .missing
        }

        // A video timestamp with an explicit +/- timezone is safer than QuickTime's ambiguous fields.
        let exactCandidates = matches("Keys", "CreationDate") + matches("UserData", "DateTimeOriginal")
            + matches("QuickTime", "CreationDate") + matches("ItemList", "ContentCreateDate")
        for v in exactCandidates where hasZone(v.value) {
            if var found = candidate([v], high: true, explanation: "영상 원본에 명시된 시간대 포함") {
                if let a = found.stamp {
                    for other in exactCandidates where other.key != v.key && hasZone(other.value) {
                        if let b = CaptureStamp.parse(other.value),
                           (a.compactDate != b.compactDate || a.compactTime != b.compactTime) {
                            found.confidence = .review
                            found.details += " · 다른 영상 날짜 태그(\(other.key))와 불일치: " + b.formatted
                        }
                    }
                    if let xml = sonyXMLDate(for: file), let b = xml.stamp,
                       (a.compactDate != b.compactDate || a.compactTime != b.compactTime) {
                        found.confidence = .review
                        found.details += " · Sony XML과 일시 불일치: " + b.formatted
                    }
                }
                return found
            }
        }
        if let xml = sonyXMLDate(for: file) { return xml }
        if let value = candidate(exactCandidates, high: false, explanation: "영상 내부 기록이나 시간대가 명확하지 않습니다") { return value }
        if let value = candidate(matches("QuickTime", "CreateDate") + anyTag("MediaCreateDate") + anyTag("TrackCreateDate"),
                                 high: false, explanation: "QuickTime 시간대 불명확 (UTC 또는 카메라 현지시각일 수 있음)") { return value }
        return .missing
    }

    private func sonyXMLDate(for video: URL) -> CaptureEvidence? {
        for match in SidecarMatcher.candidates(for: video, allowedExtensions: ["XML", "xml"]) {
            let xml = match.source
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: xml.path),
                  let count = attrs[.size] as? NSNumber, count.intValue <= 4_000_000,
                  let contents = try? String(contentsOf: xml, encoding: .utf8) else { continue }
            let pattern = #"(?:CreationDate|CreationDateTime|ShootingDateTime)[^>]{0,500}?(?:value|date)\s*=\s*\"([^\"]+)\""#
            let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let ns = contents as NSString
            guard let m = re.firstMatch(in: contents, range: NSRange(location: 0, length: ns.length)) else { continue }
            let raw = ns.substring(with: m.range(at: 1))
            guard let date = CaptureStamp.parse(raw) else { continue }
            let explicitOffset = raw.range(of: #"[+-](?:0\d|1[0-4]):?[0-5]\d\s*$"#, options: .regularExpression) != nil
            return CaptureEvidence(stamp: date, confidence: explicitOffset ? .high : .review,
                                   source: "Sony XML (동일 클립: \(xml.lastPathComponent))",
                                   details: explicitOffset ? "카메라 XML 촬영일시·시간대 포함: \(raw)" : "XML의 시간대 또는 현지시각 확인 필요: \(raw)")
        }
        return nil
    }
}
