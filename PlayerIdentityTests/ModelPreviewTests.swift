import XCTest
@testable import PlayerIdentity

/// Produces an 8-bit paletted BMP for tests (same format as the game BMPs).
enum BMPFixture {
    static func paletted(width: Int, height: Int) -> Data {
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        let rowSize = (width + 3) / 4 * 4
        let pixelBytes = rowSize * height
        let offset = 14 + 40 + 256 * 4
        var bytes: [UInt8] = Array("BM".utf8) + le32(offset + pixelBytes) + le32(0) + le32(offset)
        bytes += le32(40) + le32(width) + le32(height) + le16(1) + le16(8) + le32(0) + le32(pixelBytes)
            + le32(2834) + le32(2834) + le32(256) + le32(0)
        for i in 0..<256 { bytes += [UInt8(i), UInt8(255 - i), UInt8(i / 2), 0] }
        for y in 0..<height {
            for x in 0..<rowSize { bytes.append(x < width ? UInt8((x + y) % 256) : 0) }
        }
        return Data(bytes)
    }
}

final class ModelPreviewTests: XCTestCase {
    private var temp: TempDirectory!
    private var gamedir: URL { temp.url.appendingPathComponent("valve", isDirectory: true) }

    override func setUpWithError() throws {
        temp = try TempDirectory()
        _ = try temp.makeDirectory("valve/models/player")
    }

    override func tearDown() {
        temp = nil
    }

    func testModelWithBMPIsFoundAndDecoded() throws {
        try temp.write("valve/models/player/barney/barney.bmp", BMPFixture.paletted(width: 164, height: 200))
        try temp.write("valve/models/player/barney/barney.mdl", "mdl")
        let url = try XCTUnwrap(ModelPreviewLocator.imageURL(gamedir: gamedir, model: "barney"))
        XCTAssertEqual(url.lastPathComponent, "barney.bmp")
        let image = try XCTUnwrap(ModelPreview.load(gamedir: gamedir, model: "barney").image)
        XCTAssertEqual(image.pixelWidth, 164)
        XCTAssertEqual(image.pixelHeight, 200)
        XCTAssertEqual(image.url.lastPathComponent, "barney.bmp")
    }

    func testModelWithoutBMPIsPlaceholder() throws {
        try temp.write("valve/models/player/gman/Gman.mdl", "mdl")
        XCTAssertNil(ModelPreviewLocator.imageURL(gamedir: gamedir, model: "gman"))
        XCTAssertEqual(ModelPreview.load(gamedir: gamedir, model: "gman"), .placeholder)
        XCTAssertEqual(ModelPreview.load(gamedir: gamedir, model: "yok"), .placeholder)   // no folder
        XCTAssertEqual(ModelPreview.load(gamedir: gamedir, model: ""), .placeholder)
        XCTAssertEqual(ModelPreview.placeholderSymbol, "person.crop.square")
    }

    func testCorruptAndEmptyBMPArePlaceholders() throws {
        try temp.write("valve/models/player/empty/empty.bmp", Data())
        try temp.write("valve/models/player/broken/broken.bmp", "BM bu bir görsel değil")
        var truncated = BMPFixture.paletted(width: 16, height: 16)
        truncated.removeSubrange(60..<truncated.count)
        try temp.write("valve/models/player/cut/cut.bmp", truncated)
        for model in ["empty", "broken", "cut"] {
            XCTAssertNotNil(ModelPreviewLocator.imageURL(gamedir: gamedir, model: model), model)
            XCTAssertEqual(ModelPreview.load(gamedir: gamedir, model: model), .placeholder, model)
        }
        XCTAssertNil(ModelPreview.decode(Data()))
    }

    func testFileNameCaseDifferencesAreFoundAndSortedCaseInsensitively() throws {
        try temp.write("valve/models/player/robo/Robo.bmp", BMPFixture.paletted(width: 4, height: 5))
        try temp.write("valve/models/player/tmcm/TMCM.bmp", BMPFixture.paletted(width: 4, height: 5))
        try temp.write("valve/models/player/multi/b.bmp", BMPFixture.paletted(width: 4, height: 5))
        try temp.write("valve/models/player/multi/A.bmp", BMPFixture.paletted(width: 6, height: 5))
        try temp.write("valve/models/player/multi/c.txt", "x")
        XCTAssertEqual(ModelPreviewLocator.imageURL(gamedir: gamedir, model: "robo")?.lastPathComponent, "Robo.bmp")
        XCTAssertEqual(ModelPreviewLocator.imageURL(gamedir: gamedir, model: "tmcm")?.lastPathComponent, "TMCM.bmp")
        XCTAssertEqual(ModelPreviewLocator.imageURL(gamedir: gamedir, model: "multi")?.lastPathComponent, "A.bmp")
        XCTAssertEqual(ModelPreview.load(gamedir: gamedir, model: "multi").image?.pixelWidth, 6)
    }

    func testUppercaseExtensionIsMatched() throws {
        // §16.2 (v1.5): the extension is case-insensitive too → `gman.BMP` is found and decoded.
        try temp.write("valve/models/player/gman/gman.BMP", BMPFixture.paletted(width: 4, height: 5))
        try temp.write("valve/models/player/mixed/b.Bmp", BMPFixture.paletted(width: 4, height: 5))
        try temp.write("valve/models/player/mixed/A.BMP", BMPFixture.paletted(width: 7, height: 5))
        XCTAssertEqual(ModelPreviewLocator.imageURL(gamedir: gamedir, model: "gman")?.lastPathComponent, "gman.BMP")
        XCTAssertEqual(ModelPreview.load(gamedir: gamedir, model: "gman").image?.pixelWidth, 4)
        XCTAssertEqual(ModelPreviewLocator.imageURL(gamedir: gamedir, model: "mixed")?.lastPathComponent, "A.BMP")
        XCTAssertNil(ModelPreviewLocator.imageURL(gamedir: gamedir, model: "mixed2"))
    }

    func testCacheReusesDecodeUntilMtimeChanges() async throws {
        let file = try temp.write("valve/models/player/gina/gina.bmp", BMPFixture.paletted(width: 4, height: 5))
        try temp.write("valve/models/player/gman/Gman.mdl", "mdl")
        let cache = ModelPreviewCache()
        let first = await cache.previews(gamedir: gamedir, models: ["gina", "gman"])
        XCTAssertNotNil(first["gina"]?.image)
        XCTAssertEqual(first["gman"], .placeholder)
        let decodesAfterFirst = await cache.decodeCount
        XCTAssertEqual(decodesAfterFirst, 2)

        let second = await cache.previews(gamedir: gamedir, models: ["gina", "gman"])
        XCTAssertEqual(second, first)
        let decodesAfterSecond = await cache.decodeCount
        XCTAssertEqual(decodesAfterSecond, 2)                      // from the cache

        try BMPFixture.paletted(width: 8, height: 5).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: file.path)
        let third = await cache.previews(gamedir: gamedir, models: ["gina"])
        XCTAssertEqual(third["gina"]?.image?.pixelWidth, 8)         // mtime changed → decoded again
        let decodesAfterThird = await cache.decodeCount
        XCTAssertEqual(decodesAfterThird, 3)
    }

    func testAspectFitKeepsRatio() {
        let rect = ModelPreviewStyle.aspectFit(CGSize(width: 164, height: 200), in: CGRect(x: 0, y: 0, width: 56, height: 68))
        XCTAssertEqual(rect.width / rect.height, 164.0 / 200.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(rect.width, 56)
        XCTAssertLessThanOrEqual(rect.height, 68)
        XCTAssertEqual(rect.midX, 28, accuracy: 0.0001)
        XCTAssertEqual(rect.midY, 34, accuracy: 0.0001)
    }

    // MARK: Real game files (read-only; skipped if absent)

    private var realRoot: URL {
        AppPaths().defaultDataRoot
    }

    func testRealBarneyAndGmanDecode() throws {
        let valve = realRoot.appendingPathComponent("valve", isDirectory: true)
        let barney = ModelPreviewLocator.folder(gamedir: valve, model: "barney")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: barney.path), "gerçek valve/barney yok")
        let image = try XCTUnwrap(ModelPreview.load(gamedir: valve, model: "barney").image)
        XCTAssertGreaterThan(image.pixelWidth, 0)
        XCTAssertGreaterThan(image.pixelHeight, 0)

        let gman = ModelPreviewLocator.folder(gamedir: valve, model: "gman")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: gman.path), "gerçek valve/gman yok")
        // `gman.BMP` (uppercase extension) is found and decoded (§16.2, v1.5).
        let gmanImage = try XCTUnwrap(ModelPreview.load(gamedir: valve, model: "gman").image)
        XCTAssertEqual(gmanImage.url.pathExtension, "BMP")
        XCTAssertGreaterThan(gmanImage.pixelWidth, 0)
    }

    func testRealCoverageCounts() throws {
        for (gamedir, expectedImages, expectedTotal) in [("valve", 14, 14), ("gearbox", 15, 15)] {
            let url = realRoot.appendingPathComponent(gamedir, isDirectory: true)
            guard let models = ModelCatalog.load(gamedir: url) else {
                throw XCTSkip("gerçek \(gamedir)/models/player yok")
            }
            let withImage = models.filter { ModelPreview.load(gamedir: url, model: $0).image != nil }
            XCTAssertEqual(models.count, expectedTotal, gamedir)
            XCTAssertEqual(withImage.count, expectedImages, gamedir)
        }
    }
}

@MainActor
final class ModelPreviewModelTests: XCTestCase {
    func testPreviewsLoadAndReloadOnGamedirChange() async throws {
        let temp = try TempDirectory()
        let suite = "PlayerIdentityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = "home/Library/Application Support/Xash3D FWGS"
        try temp.write("home/.config/.xash_id", "0123456789ABCDEF")
        try temp.write("\(root)/valve/config.cfg", "name \"A\"\nmodel \"gordon\"\n")
        try temp.write("\(root)/valve/models/player/gordon/gordon.bmp", BMPFixture.paletted(width: 4, height: 5))
        try temp.write("\(root)/valve/models/player/gman/Gman.mdl", "mdl")
        try temp.write("\(root)/gearbox/config.cfg", "name \"A\"\nmodel \"otis\"\n")
        try temp.write("\(root)/gearbox/models/player/otis/otis.bmp", BMPFixture.paletted(width: 6, height: 5))
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        let model = AppModel(dependencies: AppDependencies(
            paths: AppPaths(home: home),
            fileSystem: LocalFileSystem(),
            localIPProvider: FixedLocalIPProvider(addresses: []),
            publicIPClient: PublicIPClient(http: ScriptedHTTPClient(script: HTTPScript(defaultBody: nil))),
            snapshotStore: SnapshotStore(fileURL: temp.url.appendingPathComponent("profile.json")),
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_793_000_000) },
            udpTransport: FakeServer.healthy(),
            gameProcessDetector: FakeGameDetector(),
            commandRunner: FakeCommandRunner(),
            sleeper: FakeSleeper(clock: TestClock())))

        await model.refresh().value
        await model.waitForPreviews()
        XCTAssertEqual(model.preview(for: "gordon")?.image?.pixelWidth, 4)
        XCTAssertEqual(model.preview(for: "gman"), .placeholder)
        XCTAssertFalse(model.isLoadingPreviews)

        await model.selectGamedir("gearbox")?.value
        await model.waitForPreviews()
        XCTAssertNil(model.preview(for: "gordon"))                  // old gamedir images cleared
        XCTAssertEqual(model.preview(for: "otis")?.image?.pixelWidth, 6)
        XCTAssertEqual(model.modelDraft, "otis")

        await model.selectGamedir("valve")?.value
        await model.waitForPreviews()
        XCTAssertEqual(model.preview(for: "gordon")?.image?.pixelWidth, 4)
    }
}
