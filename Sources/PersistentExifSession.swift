import Foundation

// Transport-only optimization. MetadataReader.interpret and the selected ExifTool tags
// must not be altered by this session. On any protocol error, fall back to v0.1's
// per-batch Process invocation (and never label an unparsed result as trustworthy).
final class PersistentExifSession {
    private let reader: MetadataReader
    private let condition = NSCondition()
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var buffered = Data()
    private var ended = false
    private var requestID = 0
    private var disabled = false

    init(reader: MetadataReader) { self.reader = reader }

    func readBatch(_ inputs: [MediaInput]) -> [String: CaptureEvidence] {
        if !disabled && !inputs.contains(where: { $0.url.path.contains("\n") || $0.url.path.contains("\r") }) {
            do {
                let data = try query(inputs)
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw SessionError.invalidResponse
                }
                var result: [String: CaptureEvidence] = [:]
                for row in rows {
                    guard let path = row["SourceFile"] as? String else { continue }
                    result[path] = reader.interpret(row: row, file: URL(fileURLWithPath: path))
                }
                guard inputs.allSatisfy({ result[$0.url.path] != nil }) else { throw SessionError.invalidResponse }
                return result
            } catch {
                disabled = true
                close()
            }
        }
        return reader.readBatch(inputs)
    }

    private enum SessionError: Error { case invalidResponse, sessionClosed, timedOut, responseTooLarge }

    private func startIfNeeded() throws {
        if process != nil { return }
        let p = Process()
        let input = Pipe()
        let output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.currentDirectoryURL = reader.toolURL.deletingLastPathComponent()
        p.arguments = [reader.toolURL.path, "-stay_open", "True", "-@", "-"]
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        let outputHandle = output.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let received = handle.availableData
            guard let self else { return }
            self.condition.lock()
            if received.isEmpty { self.ended = true }
            else { self.buffered.append(received) }
            self.condition.broadcast()
            self.condition.unlock()
        }
        do { try p.run() }
        catch { outputHandle.readabilityHandler = nil; throw error }
        process = p
        standardInput = input.fileHandleForWriting
        standardOutput = outputHandle
        ended = false
    }

    private func query(_ inputs: [MediaInput]) throws -> Data {
        try startIfNeeded()
        requestID += 1
        let id = requestID
        let command = (MetadataReader.exifArguments + inputs.map { $0.url.path } + ["-execute\(id)"])
            .joined(separator: "\n") + "\n"
        try standardInput?.write(contentsOf: Data(command.utf8))
        let marker = Data("\n{ready\(id)}\n".utf8)
        let deadline = Date().addingTimeInterval(180)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let range = buffered.range(of: marker) {
                let json = buffered.subdata(in: 0..<range.lowerBound)
                buffered.removeSubrange(0..<range.upperBound)
                return json
            }
            if ended || process?.isRunning == false { throw SessionError.sessionClosed }
            if buffered.count > 32 * 1024 * 1024 { throw SessionError.responseTooLarge }
            guard condition.wait(until: deadline) else { throw SessionError.timedOut }
        }
    }

    func close() {
        condition.lock()
        let p = process
        process = nil
        ended = true
        condition.broadcast()
        condition.unlock()
        standardOutput?.readabilityHandler = nil
        if let p, p.isRunning {
            try? standardInput?.write(contentsOf: Data("-stay_open\nFalse\n".utf8))
            // ExifTool normally exits promptly. terminate prevents a hung child from surviving the scan.
            if p.isRunning { p.terminate() }
        }
        standardInput = nil
        standardOutput = nil
    }
    deinit { close() }
}
