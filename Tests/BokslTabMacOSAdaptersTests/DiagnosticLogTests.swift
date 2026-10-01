import Foundation
import XCTest
@testable import BokslTabMacOSAdapters

final class DiagnosticLogTests: XCTestCase {
    func testQueuedWritesRotateWithoutGrowingEitherFilePastLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.log")
        let log = FileDiagnosticLog(fileURL: file, maximumBytes: 256)
        for index in 0..<100 { log.write("message \(index)") }
        log.flush()
        let current = try Data(contentsOf: file)
        let previous = try Data(contentsOf: file.appendingPathExtension("previous"))
        XCTAssertLessThanOrEqual(current.count, 256)
        XCTAssertLessThanOrEqual(previous.count, 256)
        XCTAssertTrue(String(decoding: current, as: UTF8.self).contains("message 99"))
    }
}
