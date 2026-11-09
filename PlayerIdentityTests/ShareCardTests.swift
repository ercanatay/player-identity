import CoreImage
import ImageIO
import XCTest
@testable import PlayerIdentity

/// §33 CID share card: size, content, QR, truncation, missing fields.
final class ShareCardTests: XCTestCase {
    private static let cid = "d9de0eb4419608a8423241430581e91c"

    private func content(name: String = "POLIGON RPG", player: String = "Oyuncu") -> ShareCardContent {
        ShareCardContent(serverName: name, hostPort: "192.0.2.10:27015", cid: Self.cid, playerName: player,
                         dateText: "09.11.2026 13:45",
                         labels: ShareCardLabels(title: "Oyuncu Kimlik Kartı", server: "Sunucu", cid: "CID",
                                                 player: "Oyuncu", date: "Tarih"),
                         icon: Self.icon())
    }

    /// Plain green square standing in for the app icon.
    private static func icon() -> CGImage? {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.4, alpha: 1))
        context?.fill(CGRect(x: 8, y: 8, width: 48, height: 48))
        return context?.makeImage()
    }

    private func decode(_ png: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func qrMessages(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    func testCardIs1200x630PNGAndNotEmpty() throws {
        let png = try XCTUnwrap(ShareCardRenderer.png(content()))
        XCTAssertGreaterThan(png.count, 10_000)
        let image = try decode(png)
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 630)
        // More than the background: text and QR add many distinct colours.
        XCTAssertGreaterThan(distinctColours(image), 50)
        // Pure: the same content gives the same bytes.
        XCTAssertEqual(ShareCardRenderer.png(content()), png)
    }

    func testQRCodeHoldsTheCID() throws {
        let qr = try XCTUnwrap(ShareCardRenderer.qrCode(Self.cid, side: 300))
        XCTAssertEqual(qr.width, 300)
        XCTAssertEqual(qrMessages(qr), [Self.cid])
        XCTAssertNil(ShareCardRenderer.qrCode("", side: 300))
        // The QR on the card can be read back.
        let card = try decode(try XCTUnwrap(ShareCardRenderer.png(content())))
        XCTAssertEqual(qrMessages(card), [Self.cid])
    }

    func testLongNamesAreTruncated() throws {
        XCTAssertEqual(ShareCardText.truncated("kisa", maxCharacters: 10), "kisa")
        let long = String(repeating: "Çok Uzun Sunucu Adı ", count: 10)
        let cut = ShareCardText.truncated(long, maxCharacters: ShareCardRenderer.maxNameCharacters)
        XCTAssertEqual(cut.count, ShareCardRenderer.maxNameCharacters)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertEqual(ShareCardText.truncated("a\nb", maxCharacters: 10), "a b")
        XCTAssertEqual(ShareCardText.truncated(" \n ", maxCharacters: 10), "—")
        let image = try decode(try XCTUnwrap(ShareCardRenderer.png(content(name: long, player: long))))
        XCTAssertEqual(image.width, 1200)
    }

    func testMissingFieldsDoNotCrash() throws {
        let empty = try XCTUnwrap(ShareCardRenderer.png(ShareCardContent()))
        let image = try decode(empty)
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 630)
        XCTAssertEqual(qrMessages(image), [])   // no CID → no QR
        var noIcon = content()
        noIcon.icon = nil
        XCTAssertNotNil(ShareCardRenderer.png(noIcon))
    }

    private func distinctColours(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var seen = Set<UInt32>()
        let step = image.bitsPerPixel / 8
        for offset in stride(from: 0, to: CFDataGetLength(data) - 3, by: step * 7) {
            seen.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
        }
        return seen.count
    }
}
