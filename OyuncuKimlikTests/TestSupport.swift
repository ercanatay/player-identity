import Foundation
import XCTest

/// Her test için ayrı geçici klasör; kullanıcının gerçek dosyalarına dokunulmaz.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OyuncuKimlikTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String) throws -> URL {
        try write(relativePath, Data(contents.utf8))
    }

    @discardableResult
    func write(_ relativePath: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func makeDirectory(_ relativePath: String) throws -> URL {
        let dir = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(relativePath))
    }
}
