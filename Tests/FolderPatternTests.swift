import Foundation

@main
struct FolderPatternTests {
    static func main() throws {
        func verify(_ okay: Bool, _ label: String) {
            if !okay { fputs("FAIL: \(label)\n", stderr); exit(1) }
        }
        let stamp = CaptureStamp.parse("2026:11:20 15:32:08")!
        let simple = try FolderPattern.render("{YYYY}년/{MM}월/{YYYY}.{MM}.{DD}_", stamp: stamp)
        verify(simple == "2026년/11월/2026.11.20_", "unquoted example")
        let quoted = try FolderPattern.render("{YYYY}\"년\"/{MM}\"월\"/{YYYY}\".\"{MM}\".\"{DD}\"_\"", stamp: stamp)
        verify(quoted == simple, "quoted literal example")
        verify(try FolderPattern.render("{YYYYMMDD}/{hhmmss}", stamp: stamp) == "20261120/153208", "date time tokens")
        for value in ["", "/{YYYY}", "{YYYY}/", "{YYYY}//{MM}", "../{YYYY}", "./{MM}", "{Originalname}", "{filename}", "{YYYY}/{unknown}", "{YYYY}:bad", "{YYYY}\\bad", "{YYYY}*", "{YYYY}\"unclosed", "{YYYY}\"/\"{MM}", "{YYYY}\n{MM}"] {
            var rejected = false
            do { _ = try FolderPattern.render(value, stamp: stamp) } catch { rejected = true }
            verify(rejected, "reject unsafe folder rule: \(value)")
        }
        print("PASS: folder date tokens / quoted literals / safe relative paths / traversal and token rejection")
    }
}
