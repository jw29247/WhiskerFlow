import XCTest
@testable import WhiskerFlowAppSupport

final class ResourceDiagnosticSamplerTests: XCTestCase {
    func testNativeSnapshotReportsCountersWithoutProcessContent() throws {
        let sampler = ResourceDiagnosticSampler()
        let first = sampler.snapshot()
        let second = sampler.snapshot()
        XCTAssertEqual(first["event"], "resource_snapshot")
        XCTAssertGreaterThan(try XCTUnwrap(Double(first["rss_bytes"] ?? "")), 0)
        XCTAssertGreaterThan(try XCTUnwrap(Double(first["cpu_count"] ?? "")), 0)
        XCTAssertNotNil(first["swap_used_bytes"])
        XCTAssertNotNil(second["app_cpu_percent"])
        XCTAssertNil(first["app_cpu_percent"], "CPU percent needs a baseline")
        for key in ["rss_bytes", "load_1m", "swap_used_bytes", "app_cpu_percent"] {
            if let raw = second[key] { XCTAssertTrue(try XCTUnwrap(Double(raw)).isFinite) }
        }
        XCTAssertNil(first["command"])
        XCTAssertNil(first["path"])
    }
}
