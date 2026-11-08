import Foundation

/// Salt okunur dosya sistemi erişimi (§1, §9). Oyun dosyalarına yazma yöntemi bilerek yoktur.
protocol FileSystemReading: Sendable {
    func isRegularFile(_ url: URL) -> Bool
    func isDirectory(_ url: URL) -> Bool
    func readData(_ url: URL) throws -> Data
    func contentsOfDirectory(_ url: URL) throws -> [URL]
}

struct LocalFileSystem: FileSystemReading {
    init() {}

    func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func readData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func contentsOfDirectory(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}

/// Varsayılan konumlar (§2, §5).
struct AppPaths: Sendable, Equatable {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private var applicationSupport: URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    /// `~/Library/Application Support/Xash3D FWGS`
    var defaultDataRoot: URL {
        applicationSupport.appendingPathComponent("Xash3D FWGS", isDirectory: true)
    }

    /// `~/Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json`
    var snapshotFile: URL {
        applicationSupport.appendingPathComponent("tr.ercanatay.oyuncukimlik", isDirectory: true)
            .appendingPathComponent("profile.json", isDirectory: false)
    }
}
