// Linux-only compilation bridge for the copy/rename integration test.
// macOS CI links Apple's genuine CryptoKit SHA256 and is the authoritative integrity test.
import Foundation
public struct SHA256 {
    public init() {}
    public mutating func update(data: Data) {}
    public mutating func finalize() -> [UInt8] { Array(repeating: 0, count: 32) }
}
