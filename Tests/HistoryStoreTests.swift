import Foundation

@main
struct HistoryStoreTests {
    static func main() throws {
        func verify(_ value: Bool, _ label: String) { if !value { fputs("FAIL \(label)\n", stderr); exit(1) } }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("00CaptureDate-HistoryTests-" + UUID().uuidString)
        let source = temp.appendingPathComponent("Original")
        let destination = temp.appendingPathComponent("Target")
        let storage = temp.appendingPathComponent("Database")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let history = try HistoryStore(directory: storage)
        func entry(_ url: URL) throws -> MediaEntry {
            let r = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let input = MediaInput(url: url, size: Int64(r.fileSize ?? 0), relativeFolder: "Original", modified: r.contentModificationDate)
            return MediaEntry(source: input, evidence: CaptureEvidence(stamp: CaptureStamp.parse("2026:11:21 09:07:05"), confidence: .high, source: "ExifIFD", details: "test"), ordinal: 1)
        }
        func plan(_ url: URL, mode: WorkMode) throws -> WorkPlan {
            let preflight = Planner.prepare([try entry(url)], pattern: NamePattern.defaultValue, mode: mode,
                                            destination: destination, preserveFolders: false)
            verify(preflight.plans.count == 1, "plan available")
            return preflight.plans[0]
        }
        let original = source.appendingPathComponent("A.HIF")
        let xml = source.appendingPathComponent("A.XMP")
        try Data("123456789 test".utf8).write(to: original)
        try Data("sidecar".utf8).write(to: xml)
        let toRename = try plan(original, mode: .rename)
        let job = try history.beginJob(mode: .rename, logURL: temp.appendingPathComponent("log.jsonl"))
        let item = try history.prepareItem(jobID: job, plan: toRename, mode: .rename)
        _ = try FileOperator.process(plan: toRename, mode: .rename, control: WorkControl())
        try history.markSuccess(item, plan: toRename)
        try history.finishJob(job, interrupted: false)
        verify(try history.jobs().first?.completedCount == 1, "persisted success")
        verify(try HistoryStore(directory: storage).items(jobID: job).first?.state == "success", "reopen database")
        try history.restoreItem(item)
        verify(fm.fileExists(atPath: original.path), "restored original file")
        verify(fm.fileExists(atPath: xml.path), "restored sidecar")
        verify(!fm.fileExists(atPath: toRename.output.path), "renamed output removed")
        verify(try history.items(jobID: job).first?.state == "restored", "restoration recorded")
        do { try history.restoreItem(item); verify(false,"no double restore") } catch {}

        // A conflicting original filename must not be overwritten.
        let conflictPlan = try plan(original, mode: .rename)
        let conflictJob = try history.beginJob(mode: .rename, logURL: temp.appendingPathComponent("log2.jsonl"))
        let conflictItem = try history.prepareItem(jobID: conflictJob, plan: conflictPlan, mode: .rename)
        _ = try FileOperator.process(plan: conflictPlan, mode: .rename, control: WorkControl())
        try history.markSuccess(conflictItem, plan: conflictPlan)
        try history.finishJob(conflictJob, interrupted: false)
        try "other unrelated file".write(to: original, atomically: true, encoding: .utf8)
        do { try history.restoreItem(conflictItem); verify(false,"conflict must block") } catch {}
        verify(try String(contentsOf: original, encoding: .utf8) == "other unrelated file", "conflict unmodified")
        try fm.removeItem(at: original)
        // Source was replaced at produced name; inode identity must reject restore.
        let outputBytes = try Data(contentsOf: conflictPlan.output)
        try fm.removeItem(at: conflictPlan.output)
        try outputBytes.write(to: conflictPlan.output)
        do { try history.restoreItem(conflictItem); verify(false,"replacement must block") } catch {}
        verify(try history.items(jobID: conflictJob).first?.state == "success", "unsafe restore remains available for review")

        // Copy mode leaves original source untouched; restore only renames the verified copy.
        let copyOriginal = source.appendingPathComponent("B.ARW")
        try Data("copy-test".utf8).write(to: copyOriginal)
        let copyPlan = try plan(copyOriginal, mode: .copy)
        let copyJob = try history.beginJob(mode: .copy, logURL: temp.appendingPathComponent("log3.jsonl"))
        let copyItem = try history.prepareItem(jobID: copyJob, plan: copyPlan, mode: .copy)
        let hash = try FileOperator.process(plan: copyPlan, mode: .copy, control: WorkControl())
        verify(hash?.count == 64, "SHA verified")
        try history.markSuccess(copyItem, plan: copyPlan)
        try history.finishJob(copyJob, interrupted: false)
        try history.restoreItem(copyItem)
        verify(fm.fileExists(atPath: copyOriginal.path), "original survives copied-file restore")
        verify(fm.fileExists(atPath: destination.appendingPathComponent("B.ARW").path), "copy gets old basename")

        // Expiration uses job finish time and never changes media.
        verify(try history.prune(days: 30, now: Date().addingTimeInterval(31*86400)) == 3, "old sessions expired")
        verify(try history.jobs().isEmpty, "pruned DB")
        verify(fm.fileExists(atPath: copyOriginal.path), "prune leaves media")
        let inProgress = try history.beginJob(mode: .rename, logURL: temp.appendingPathComponent("newlog.jsonl"))
        do { _ = try history.clearAll(); verify(false,"active session prohibits empty") } catch {}
        try history.finishJob(inProgress, interrupted: true)
        verify(try history.clearAll() == 1, "manual clear")
        verify(try history.jobs().isEmpty, "empty confirmed")
        print("PASS: SQLite history / reopen / paired undo / duplicate guard / inode guard / copy undo / retention / clear")
    }
}
