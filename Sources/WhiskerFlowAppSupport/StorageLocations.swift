import Foundation

public enum StorageLocations {
    public static let directoryName = "WhiskerFlow"

    public static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Launch-path variant: an unavailable Application Support directory degrades
    /// to a temporary location instead of taking the app down with it.
    public static func applicationSupportRootOrTemporary(
        fileManager: FileManager = .default
    ) -> URL {
        (try? applicationSupportRoot(fileManager: fileManager))
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
    }
}
