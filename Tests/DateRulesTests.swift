import Foundation

@main
struct DateRulesTests {
    static func main() throws {
        func check(_ passed: Bool, _ message: String) {
            if !passed { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        let d = CaptureStamp.parse("2026:11:21 09:07:05+09:00")!
        check(d.compactDate == "20261121", "EXIF date")
        check(d.compactTime == "090705", "local camera time")
        check(CaptureStamp.parse("2026-11-21T09:07:05+09:00") == d, "ISO timezone")
        check(CaptureStamp.parse("2026:02:30 12:10:11") == nil, "invalid day")
        check(CaptureStamp.parse("0000:00:00 00:00:00") == nil, "invalid blank EXIF")
        check(CaptureStamp.parse("2026:11:21 25:00:00") == nil, "invalid hour")
        let u = URL(fileURLWithPath: "/tmp/_DSC3015.HIF")
        let a = try NamePattern.render(NamePattern.defaultValue, stamp: d, originalURL: u, ordinal: 1)
        check(a == "20261121_090705__DSC3015.HIF", "default rule and HIF")
        let b = try NamePattern.render("{YYYY}-{MM}-{DD}_{hh}{mm}{ss}_{filename}_{SEQ}", stamp: d, originalURL: u, ordinal: 2)
        check(b == "2026-11-21_090705__DSC3015_0002.HIF", "custom rule")
        do { _ = try NamePattern.render("{UNKNOWN}", stamp: d, originalURL: u, ordinal: 1); check(false, "unknown token") }
        catch { }
        print("PASS: date parsing / validation / HIF / rename pattern / unknown token")
    }
}
