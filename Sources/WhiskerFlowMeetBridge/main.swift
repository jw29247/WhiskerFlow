import Foundation
import WhiskerFlowAppSupport

// Chrome launches this host. Stdout is exclusively length-prefixed protocol data.
func readExactly(_ count: Int) -> Data? {
    var result = Data()
    while result.count < count {
        guard let chunk = try? FileHandle.standardInput.read(upToCount: count - result.count), !chunk.isEmpty else { return nil }
        result.append(chunk)
    }
    return result
}
while let header = readExactly(4) {
    let length = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
    guard length > 0, length <= 65536, let body = readExactly(length) else { break }
    let accepted = (try? MeetingBrowserInbox.accept(body)) ?? false
    let response = Data((accepted ? "{\"accepted\":true}" : "{\"accepted\":false}").utf8)
    var size = UInt32(response.count).littleEndian
    FileHandle.standardOutput.write(withUnsafeBytes(of: &size) { Data($0) })
    FileHandle.standardOutput.write(response)
}
