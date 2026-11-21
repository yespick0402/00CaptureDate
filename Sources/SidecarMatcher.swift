import Foundation

struct SidecarPair {
    let source: URL
    let suffix: String
    let ext: String
}

enum SidecarMatcher {
    // Sony cameras commonly store C0001.MP4 with C0001M01.XML.
    // Match only exact conservative names, not similarly numbered neighboring clips.
    static func candidates(for media: URL, allowedExtensions: [String] = ["xmp", "XMP", "xml", "XML"]) -> [SidecarPair] {
        let base = media.deletingPathExtension().path
        let suffixes = MediaInventory.movie.contains(media.pathExtension.lowercased())
            ? ["", "M01", "M02", "S01"] : [""]
        var result: [SidecarPair] = []
        var seenFileIDs = Set<String>()
        let fm = FileManager.default
        for suffix in suffixes {
            for ext in allowedExtensions {
                let candidate = URL(fileURLWithPath: base + suffix + "." + ext)
                guard let attrs = try? fm.attributesOfItem(atPath: candidate.path),
                      attrs[.type] as? FileAttributeType == .typeRegular else { continue }
                let volume = (attrs[.systemNumber] as? NSNumber)?.stringValue ?? "unknown"
                let inode = (attrs[.systemFileNumber] as? NSNumber)?.stringValue ?? candidate.path
                // macOS default APFS is case-insensitive: .xml and .XML may resolve to the SAME file.
                // Check inode identity so one sidecar is never scheduled twice.
                guard seenFileIDs.insert(volume + ":" + inode).inserted else { continue }
                let realName = (try? candidate.resourceValues(forKeys: [.nameKey]))?.name ?? candidate.lastPathComponent
                let foundExt = URL(fileURLWithPath: realName).pathExtension
                result.append(SidecarPair(source: candidate, suffix: suffix, ext: foundExt.isEmpty ? ext : foundExt))
            }
        }
        return result
    }
}
