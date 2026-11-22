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

        // A file already renamed in v0.2 may be organized without doubling its date prefix.
        let oldVersionAlreadyRenamed = Planner.prepare([renamedEntry], pattern: NamePattern.defaultValue, mode: .rename,
                                                       destination: nil, preserveFolders: false,
                                                       folderLayout: .captureDate)
        check(oldVersionAlreadyRenamed.plans.count == 1, "previously renamed file still eligible for folder-only organization")
        check(oldVersionAlreadyRenamed.plans[0].output.lastPathComponent == renamed.lastPathComponent,
              "date prefix not duplicated during later date organization")
        _ = try FileOperator.process(plan: oldVersionAlreadyRenamed.plans[0], mode: .rename, control: WorkControl())
        let reanalyzedInDateFolder = try entry(for: oldVersionAlreadyRenamed.plans[0].output)
        let preventNested = Planner.prepare([reanalyzedInDateFolder], pattern: NamePattern.defaultValue, mode: .rename,
                                            destination: nil, preserveFolders: false,
                                            folderLayout: .captureDate)
        check(preventNested.plans.isEmpty && !preventNested.issues.isEmpty,
              "already organized files are never nested into duplicate date tree")

        let video = inputDir.appendingPathComponent("C0001.MP4")
        try Data("video test bytes".utf8).write(to: video)
        let sonyXML = inputDir.appendingPathComponent("C0001M01.XML")
        try "<CreationDate value=\"2026-11-21T09:07:05+09:00\"/>".write(to: sonyXML, atomically: true, encoding: .utf8)
        let vp = Planner.prepare([try entry(for: video)], pattern: NamePattern.defaultValue, mode: .copy,
                                 destination: outputDir, preserveFolders: false)
        check(vp.plans.count == 1 && vp.plans[0].companions.count == 1, "Sony M01 sidecar plan")
        check(vp.plans[0].companions[0].to.lastPathComponent == "20261121_090705_C0001M01.XML", "Sony M01 suffix preserved")

        // Date-folder copy groups all media of the same day, independently of source subfolders.
        let datedCopyRoot = temp.appendingPathComponent("DatedOutput")
        try fm.createDirectory(at: datedCopyRoot, withIntermediateDirectories: true)
        let datedCopyResult = Planner.prepare([try entry(for: video)], pattern: NamePattern.defaultValue,
                                              mode: .copy, destination: datedCopyRoot, preserveFolders: true,
                                              folderLayout: .captureDate, folderPattern: FolderPattern.defaultValue)
        check(datedCopyResult.plans.count == 1, "dated copy preflight")
        let datedCopy = datedCopyResult.plans[0]
        check(datedCopy.output.path.contains("DatedOutput/2026년/11월/2026.11.21_/"), "date-only folder tree (not source tree)")
        let copyHash = try FileOperator.process(plan: datedCopy, mode: .copy, control: WorkControl())
        check(copyHash?.count == 64, "dated copy SHA-256")
        check(fm.fileExists(atPath: video.path), "dated copy preserves video original")
        check(fm.fileExists(atPath: datedCopy.output.path), "dated copy output exists")
        check(fm.fileExists(atPath: datedCopy.companions[0].to.path), "dated copy moves Sony XML pair")
        check(Planner.prepare([try entry(for: video)], pattern: NamePattern.defaultValue,
                              mode: .copy, destination: datedCopyRoot, preserveFolders: false,
                              folderLayout: .captureDate).plans.isEmpty, "dated copy collision never overwrites")

        // Original rename plus date layout moves inside the ORIGINAL parent folder, not to copy target.
        let dateRenameRoot = temp.appendingPathComponent("DateRenameInput")
        try fm.createDirectory(at: dateRenameRoot, withIntermediateDirectories: true)
        let dateOriginal = dateRenameRoot.appendingPathComponent("DSC4.ARW")
        try Data("original bytes".utf8).write(to: dateOriginal)
        let dateSidecar = dateRenameRoot.appendingPathComponent("DSC4.XMP")
        try Data("sidecar bytes".utf8).write(to: dateSidecar)
        let dateRenameResult = Planner.prepare([try entry(for: dateOriginal)], pattern: NamePattern.defaultValue,
                                                mode: .rename, destination: nil, preserveFolders: false,
                                                folderLayout: .captureDate, folderPattern: FolderPattern.defaultValue)
        check(dateRenameResult.plans.count == 1, "date rename preflight")
        let dateRename = dateRenameResult.plans[0]
        check(!fm.fileExists(atPath: dateRename.output.deletingLastPathComponent().path), "preflight must not create directories")
        check(dateRename.output.path.contains("DateRenameInput/2026년/11월/2026.11.21_/"), "original parent based date tree")
        _ = try FileOperator.process(plan: dateRename, mode: .rename, control: WorkControl())
        check(!fm.fileExists(atPath: dateOriginal.path) && fm.fileExists(atPath: dateRename.output.path), "dated rename actually moves original")
        check(fm.fileExists(atPath: dateRename.companions[0].to.path), "dated rename moves linked sidecar")
        check(try Data(contentsOf: dateRename.output) == Data("original bytes".utf8), "dated rename content unchanged")

        let invalidPatternResult = Planner.prepare([try entry(for: video)], pattern: NamePattern.defaultValue,
                                                   mode: .copy, destination: datedCopyRoot, preserveFolders: false,
                                                   folderLayout: .captureDate, folderPattern: "../{YYYY}")
        check(invalidPatternResult.plans.isEmpty && !invalidPatternResult.issues.isEmpty, "reject traversal at preflight")

        // No date means no automatic date folder and no file operation.
        var unknownDate = try entry(for: video)
        unknownDate.evidence = .missing
        check(Planner.prepare([unknownDate], pattern: NamePattern.defaultValue, mode: .copy,
                              destination: datedCopyRoot, preserveFolders: false,
                              folderLayout: .captureDate).plans.isEmpty, "unknown dates are not organized")

        // A pre-existing symlink in a date tree must not redirect media outside its source directory.
        let symlinkRoot = temp.appendingPathComponent("SymlinkOriginal")
        let symlinkOutside = temp.appendingPathComponent("Outside")
        try fm.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: symlinkOutside, withIntermediateDirectories: true)
        let guardedSource = symlinkRoot.appendingPathComponent("Guarded.ARW")
        try Data("protect-me".utf8).write(to: guardedSource)
        try fm.createSymbolicLink(at: symlinkRoot.appendingPathComponent("2026년"), withDestinationURL: symlinkOutside)
        let symlinkPlanResult = Planner.prepare([try entry(for: guardedSource)], pattern: NamePattern.defaultValue,
                                                mode: .rename, destination: nil, preserveFolders: false,
                                                folderLayout: .captureDate)
        check(symlinkPlanResult.plans.count == 1, "symlink plan deferred to execution safety check")
        var didRejectSymlink = false
        do { _ = try FileOperator.process(plan: symlinkPlanResult.plans[0], mode: .rename, control: WorkControl()) }
        catch { didRejectSymlink = true }
        check(didRejectSymlink && fm.fileExists(atPath: guardedSource.path), "symlink redirect blocked, source intact")
        check((try? fm.contentsOfDirectory(atPath: symlinkOutside.path))?.isEmpty == true, "symlink target never receives media")

        var unapproved = try entry(for: video)
        unapproved.evidence.confidence = .review
        check(Planner.prepare([unapproved], pattern: NamePattern.defaultValue, mode: .rename,
                              destination: nil, preserveFolders: false).plans.isEmpty,
              "uncertain dates never rename without approval")
        print("PASS: baseline / rename / copy / sidecars / dated subfolders / date folder copy+move / no overwrite / unsafe pattern rejected")
    }
}
