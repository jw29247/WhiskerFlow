import XCTest
@testable import WhiskerFlowAppSupport

final class StorageLocationsTests: XCTestCase {
    private final class EmptySearchPathFileManager: FileManager {
        override func urls(
            for directory: FileManager.SearchPathDirectory,
            in domainMask: FileManager.SearchPathDomainMask
        ) -> [URL] {
            []
        }
    }

    func testRootIsNestedInsideApplicationSupport() throws {
        let root = try StorageLocations.applicationSupportRoot()
        XCTAssertEqual(root.lastPathComponent, "WhiskerFlow")
        XCTAssertEqual(
            root.deletingLastPathComponent().standardizedFileURL,
            try XCTUnwrap(FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first).standardizedFileURL
        )
    }

    func testRootThrowsWhenApplicationSupportIsUnavailable() {
        XCTAssertThrowsError(
            try StorageLocations.applicationSupportRoot(fileManager: EmptySearchPathFileManager())
        )
    }

    func testFallbackUsesTemporaryDirectoryWhenApplicationSupportIsUnavailable() {
        let fileManager = EmptySearchPathFileManager()
        let root = StorageLocations.applicationSupportRootOrTemporary(fileManager: fileManager)
        XCTAssertEqual(
            root.standardizedFileURL,
            fileManager.temporaryDirectory
                .appendingPathComponent("WhiskerFlow", isDirectory: true)
                .standardizedFileURL
        )
    }

    func testFallbackPrefersApplicationSupportWhenAvailable() throws {
        XCTAssertEqual(
            StorageLocations.applicationSupportRootOrTemporary().standardizedFileURL,
            try StorageLocations.applicationSupportRoot().standardizedFileURL
        )
    }
}
