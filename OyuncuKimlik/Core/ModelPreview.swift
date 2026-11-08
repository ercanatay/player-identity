import CoreGraphics
import Foundation
import ImageIO

/// §16 Model önizleme: `<gamedir>/models/player/<model>/` içindeki ilk `.bmp`. Salt okunur.
///
/// Dosya seçimi: uzantısı `.bmp` olan normal dosyalar; ad karşılaştırması ve alfabetik sıralama
/// büyük/küçük harf duyarsızdır (ör. `Robo.bmp`, `TMCM.bmp` bulunur). Spec'in doğrulanmış sayımına
/// (valve 13/14, `gman` yok) uygun olarak uzantı `.bmp` biçiminde eşlenir.
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
            .filter { $0.pathExtension == fileExtension && fileSystem.isRegularFile($0) }
            .sorted { lhs, rhs in
                let a = lhs.lastPathComponent.lowercased(), b = rhs.lastPathComponent.lowercased()
                return a == b ? lhs.lastPathComponent < rhs.lastPathComponent : a < b
            }
            .first
    }
}

/// Decode edilmiş görsel. `CGImage` değişmezdir; iş parçacıkları arasında paylaşılabilir.
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
    /// BMP yok / bozuk → SF Symbol `person.crop.square`.
    case placeholder

    static let placeholderSymbol = "person.crop.square"

    var image: ModelPreviewImage? {
        if case .image(let image) = self { return image }
        return nil
    }

    /// ImageIO ile decode; 0 bayt veya bozuk veri → `nil`.
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

/// Bellek içi önbellek; anahtar (gamedir, model, mtime). Disk önbelleği yok (§16.4).
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

    /// Modellerin önizlemeleri; mtime değişmeyenler önbellekten gelir.
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
