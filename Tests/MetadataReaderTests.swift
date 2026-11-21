import Foundation

@main
struct MetadataReaderTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) {
            if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        let reader = MetadataReader(toolURL: URL(fileURLWithPath: "/nonexistent/exiftool"))
        let hif = URL(fileURLWithPath: "/tmp/_DSC3015.HIF")
        let e = reader.interpret(row: ["ExifIFD:DateTimeOriginal": "2026:11:21 10:20:30"], file: hif)
        check(e.confidence == .high, "HIF EXIF high trust")
        check(e.stamp?.compactTime == "102030", "HIF correct local camera time")
        let xmp = reader.interpret(row: ["XMP-exif:DateTimeOriginal": "2026:11:21 10:20:30"], file: hif)
        check(xmp.confidence == .review, "XMP not camera-original EXIF")
        let mov = URL(fileURLWithPath: "/tmp/VIDEO.MOV")
        let v1 = reader.interpret(row: ["Keys:CreationDate": "2026:11:21 10:20:30+09:00"], file: mov)
        check(v1.confidence == .high, "video with timezone high")
        let conflict = reader.interpret(row: ["Keys:CreationDate": "2026:11:21 10:20:30+09:00",
                                               "UserData:DateTimeOriginal": "2026:11:21 11:20:30+09:00"], file: mov)
        check(conflict.confidence == .review, "conflicting precise video tags need review")
        let v2 = reader.interpret(row: ["QuickTime:CreateDate": "2026:11:21 01:20:30"], file: mov)
        check(v2.confidence == .review, "ambiguous UTC QuickTime never high")
        let v3 = reader.interpret(row: ["Keys:CreationDate": "2026:11:21 01:20:30Z"], file: mov)
        check(v3.confidence == .review, "UTC Z without camera timezone requires review")
        let noDate = reader.interpret(row: ["File:FileCreateDate": "2026:11:21 10:20:30+09:00"], file: hif)
        check(noDate.confidence == .missing, "filesystem date not used")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("C0001.MP4")
        let sidecar = dir.appendingPathComponent("C0001M01.XML")
        try "<NonRealTimeMeta><CreationDate value=\"2026-11-21T10:20:30+09:00\"/></NonRealTimeMeta>".write(to: sidecar, atomically: true, encoding: .utf8)
        let xml = reader.interpret(row: [:], file: src)
        check(xml.confidence == .high && xml.stamp?.compactDate == "20261121", "Sony M01 XML high trust")
        let companions = SidecarMatcher.candidates(for: src)
        check(companions.count == 1 && companions[0].suffix == "M01", "Sony XML paired by C0001M01 name")
        let disagreement = reader.interpret(row: ["Keys:CreationDate": "2026-11-21T11:20:30+09:00"], file: src)
        check(disagreement.confidence == .review, "Sony XML disagreement")
        print("PASS: HIF/ARW EXIF interpretation / timezone / Sony XML / uncertainty / no filesystem fallback")
    }
}
