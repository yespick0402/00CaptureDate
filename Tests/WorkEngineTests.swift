import Foundation

@main
struct WorkEngineTests {
    static func main() throws {
        func check(_ okay: Bool, _ name: String) {
            if !okay { fputs("FAIL: \(name)\n", stderr); exit(1) }
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("00CaptureDate-test-" + UUID().uuidString)
        let inputDir = temp.appendingPathComponent("Input")
        let outputDir = temp.appendingPathComponent("Output")
        try fm.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        func entry(for url: URL, order: Int = 1, approval: Bool = false) throws -> MediaEntry {
            let props = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let input = MediaInput(url: url, size: Int64(props.fileSize ?? -1), relativeFolder: "Input", modified: props.contentModificationDate)
            return MediaEntry(source: input,
                              evidence: CaptureEvidence(stamp: CaptureStamp.parse("2026:11:21 09:07:05"), confidence: .high,
                                                        source: "ExifIFD:DateTimeOriginal", details: "test"), ordinal: order)
        }
        let original = inputDir.appendingPathComponent("_DSC3015.HIF")
        try Data("real test content of HIF file".utf8).write(to: original)
        let xmp = inputDir.appendingPathComponent("_DSC3015.XMP")
        try "XMP sidecar".write(to: xmp, atomically: true, encoding: .utf8)
        let item = try entry(for: original)

        let copyPlan = Planner.prepare([item], pattern: NamePattern.defaultValue, mode: .copy,
                                       destination: outputDir, preserveFolders: true)
        check(copyPlan.plans.count == 1 && copyPlan.issues.isEmpty, "copy preflight")
        let copy = copyPlan.plans[0]
        check(copy.output.path.contains("Output/Input/"), "preserve source directory structure")
        check(copy.companions.count == 1, "XMP association")
        let hash = try FileOperator.process(plan: copy, mode: .copy, control: WorkControl())
        check(hash?.count == 64, "streaming SHA-256 produced")
        check(fm.fileExists(atPath: original.path), "copy preserves original")
        check(fm.fileExists(atPath: copy.output.path), "copy result exists")
        check(fm.fileExists(atPath: copy.companions[0].to.path), "copy sidecar exists")
        let newBytes = try Data(contentsOf: copy.output)
        check(newBytes == Data("real test content of HIF file".utf8), "copy byte-for-byte")
        let copyAgain = Planner.prepare([item], pattern: NamePattern.defaultValue, mode: .copy,
                                       destination: outputDir, preserveFolders: true)
        check(copyAgain.plans.isEmpty && !copyAgain.issues.isEmpty, "never overwrite existing destination")

        let renamePlan = Planner.prepare([item], pattern: NamePattern.defaultValue, mode: .rename,
                                         destination: nil, preserveFolders: true)
        check(renamePlan.plans.count == 1, "rename preflight")
        _ = try FileOperator.process(plan: renamePlan.plans[0], mode: .rename, control: WorkControl())
        let renamed = renamePlan.plans[0].output
        check(fm.fileExists(atPath: renamed.path) && !fm.fileExists(atPath: original.path), "rename moves original")
        check(fm.fileExists(atPath: renamePlan.plans[0].companions[0].to.path), "rename pairs XMP")
        let renamedEntry = try entry(for: renamed)
        let idempotent = Planner.prepare([renamedEntry], pattern: NamePattern.defaultValue, mode: .rename,
                                         destination: nil, preserveFolders: false)
        check(idempotent.plans.isEmpty, "default pattern does not double-prefix on rerun")

        let video = inputDir.appendingPathComponent("C0001.MP4")
        try Data("video test bytes".utf8).write(to: video)
        let sonyXML = inputDir.appendingPathComponent("C0001M01.XML")
        try "<CreationDate value=\"2026-11-21T09:07:05+09:00\"/>".write(to: sonyXML, atomically: true, encoding: .utf8)
        let vp = Planner.prepare([try entry(for: video)], pattern: NamePattern.defaultValue, mode: .copy,
                                 destination: outputDir, preserveFolders: false)
        check(vp.plans.count == 1 && vp.plans[0].companions.count == 1, "Sony M01 sidecar plan")
        check(vp.plans[0].companions[0].to.lastPathComponent == "20261121_090705_C0001M01.XML", "Sony M01 suffix preserved")

        var unapproved = try entry(for: video)
        unapproved.evidence.confidence = .review
        check(Planner.prepare([unapproved], pattern: NamePattern.defaultValue, mode: .rename,
                              destination: nil, preserveFolders: false).plans.isEmpty,
              "uncertain dates never rename without approval")
        print("PASS: preview / nonoverwrite / copy / sidecar / rename / idempotence / Sony M01 / confidence gating")
    }
}
