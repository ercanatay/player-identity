import CoreGraphics
import Foundation
import ImageIO

/// §16 Model preview: the first `.bmp` in `<gamedir>/models/player/<model>/`. Read-only.
///
/// File selection (§16.2, v1.5): regular files with a `.bmp` extension; the search is case-insensitive
/// in **both file name and extension** (e.g. `Robo.bmp`, `TMCM.bmp`, `gman.BMP` are found), first alphabetically wins.
enum ModelPreviewLocator {
    static let fileExtension = "bmp"

    static func folder(gamedir: URL, model: String) -> URL {
        gamedir.appendingPathComponent("models/player", isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
    }

    static func imageURL(gamedir: URL, model: String,
                         fileSystem: any FileSystemReading = LocalFileSystem()) -> URL? {
        guard !model.isEmpty, !model.contains("/"),
              let entries = try? fileSystem.contentsOfDirectory(folder(gamedir: gamedir, model: model)) else { return nil }
        return entries
            .filter { $0.pathExtension.lowercased() == fileExtension && fileSystem.isRegularFile($0) }
            .sorted { lhs, rhs in
                let a = lhs.lastPathComponent.lowercased(), b = rhs.lastPathComponent.lowercased()
                return a == b ? lhs.lastPathComponent < rhs.lastPathComponent : a < b
            }
            .first
    }
}

/// Decoded image. `CGImage` is immutable; safe to share across threads.
struct ModelPreviewImage: @unchecked Sendable, Equatable {
    let cgImage: CGImage
    let url: URL

    var pixelWidth: Int { cgImage.width }
    var pixelHeight: Int { cgImage.height }

    static func == (lhs: ModelPreviewImage, rhs: ModelPreviewImage) -> Bool {
        lhs.url == rhs.url && lhs.cgImage === rhs.cgImage
    }
}

enum ModelPreview: Sendable, Equatable {
    case image(ModelPreviewImage)
    /// Missing / corrupt BMP → SF Symbol `person.crop.square`.
    case placeholder

    static let placeholderSymbol = "person.crop.square"

    var image: ModelPreviewImage? {
        if case .image(let image) = self { return image }
        return nil
    }

    /// Decoded with ImageIO; 0 bytes or corrupt data → `nil`.
    static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }
        return image
    }

    static func load(gamedir: URL, model: String, fileSystem: any FileSystemReading = LocalFileSystem()) -> ModelPreview {
        guard let url = ModelPreviewLocator.imageURL(gamedir: gamedir, model: model, fileSystem: fileSystem),
              let data = try? fileSystem.readData(url),
              let image = decode(data) else { return .placeholder }
        return .image(ModelPreviewImage(cgImage: image, url: url))
    }
}

/// In-memory cache; key (gamedir, model, mtime). No disk cache (§16.4).
actor ModelPreviewCache {
    struct Key: Hashable {
        let gamedir: String
        let model: String
        let path: String?
        let modified: Date?
    }

    private var entries: [Key: ModelPreview] = [:]
    private(set) var decodeCount = 0
    private let fileSystem: any FileSystemReading

    init(fileSystem: any FileSystemReading = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Previews of the models; those with an unchanged mtime come from the cache.
    func previews(gamedir: URL, models: [String]) -> [String: ModelPreview] {
        var result: [String: ModelPreview] = [:]
        for model in models where result[model] == nil {
            let url = ModelPreviewLocator.imageURL(gamedir: gamedir, model: model, fileSystem: fileSystem)
            let modified = url.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
            }
            let key = Key(gamedir: gamedir.standardizedFileURL.path, model: model, path: url?.path, modified: modified)
            if let cached = entries[key] {
                result[model] = cached
                continue
            }
            let preview = ModelPreview.load(gamedir: gamedir, model: model, fileSystem: fileSystem)
            decodeCount += 1
            entries[key] = preview
            result[model] = preview
        }
        return result
    }
}
