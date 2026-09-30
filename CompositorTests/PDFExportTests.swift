import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct PDFExportTests {
    private func snapshot(width: Int = 4, height: Int = 4, resolution: Double? = nil, red: Bool = true) throws -> ProjectSnapshot {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let id = UUID()
        let layers = red ? [ProjectLayerRecord(id: id, name: "Red", isVisible: true,
                                               transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height), sampling: .nearest),
                                               imageFile: "\(id).png")] : []
        var manifest = ProjectManifest(documentID: UUID(), width: width, height: height, activeLayerID: nil, layers: layers)
        manifest.resolution = resolution
        return ProjectSnapshot(manifest: manifest, images: red ? [id: ImportedImage(image: image, thumbnail: image, name: "Red")] : [:])
    }

    private func pdfPage(_ data: Data) throws -> CGPDFPage {
        let document = try #require(CGDataProvider(data: data as CFData).flatMap { CGPDFDocument($0) })
        #expect(document.numberOfPages == 1)
        return try #require(document.page(at: 1))
    }

    @Test func pageIsAsBigAsTheImagePrints() async throws {
        let data = try await ImageExporter.shared.pdfData(snapshot())
        #expect(data.prefix(5) == Data("%PDF-".utf8))
        let box = try pdfPage(data).getBoxRect(.mediaBox)
        #expect(box.width == 4 && box.height == 4)
    }

    /// The page holds the image at full resolution, read straight from the file rather than drawn.
    @Test func pageEmbedsTheImageUnresampled() async throws {
        let page = try pdfPage(await ImageExporter.shared.pdfData(snapshot(resolution: 288)))
        let dictionary = try #require(page.dictionary)
        var resources: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        var objects: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(try #require(resources), "XObject", &objects))
        var sizes: [(Int, Int)] = []
        CGPDFDictionaryApplyBlock(try #require(objects), { _, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let info = CGPDFStreamGetDictionary(stream) else { return true }
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(info, "Width", &width), CGPDFDictionaryGetInteger(info, "Height", &height) {
                sizes.append((width, height))
            }
            return true
        }, nil)
        // A 1-point page still carries all 4 × 4 pixels.
        #expect(sizes.contains { $0 == (4, 4) }, "embedded images \(sizes)")
    }

    @Test func pageDrawsTheImagesColors() async throws {
        let page = try pdfPage(await ImageExporter.shared.pdfData(snapshot()))
        let box = page.getBoxRect(.mediaBox)
        // Drawn back ten times larger so the check reads well inside the image, away from any edge smoothing.
        let side = 40, stride = side * 4
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: stride,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: CGFloat(side) / box.width, y: CGFloat(side) / box.height)
        context.drawPDFPage(page)
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        let center = (side / 2) * stride + (side / 2) * 4
        let rgba = (0..<4).map { Int(pixels[center + $0]) }
        // Color management on the way through the PDF can move a channel a little; red stays red.
        #expect(rgba[0] > 230 && rgba[1] < 25 && rgba[2] < 25 && rgba[3] > 245, "center pixel \(rgba)")
    }

    @Test func documentResolutionSetsThePageSize() async throws {
        // 4 px at 144 pixels/inch is 1/36 inch: 2 points.
        let box = try pdfPage(await ImageExporter.shared.pdfData(snapshot(resolution: 144))).getBoxRect(.mediaBox)
        #expect(box.width == 2 && box.height == 2)
        // 4 px at 288 pixels/inch is 1/72 inch: 1 point.
        let smaller = try pdfPage(await ImageExporter.shared.pdfData(snapshot(resolution: 288))).getBoxRect(.mediaBox)
        #expect(smaller.width == 1 && smaller.height == 1)
    }

    @Test func aPageNeverPassesTheViewersLimit() async throws {
        let big = try snapshot(width: 20_000, height: 100, red: false)
        let box = try pdfPage(await ImageExporter.shared.pdfData(big)).getBoxRect(.mediaBox)
        #expect(box.width <= ImageExporter.maxPDFPoints + 0.001)
        // Only the page shrinks; the aspect ratio holds.
        #expect(abs(box.width / box.height - 200) < 0.01)
    }

    @Test func aBlankCanvasStillMakesAPage() async throws {
        _ = try pdfPage(await ImageExporter.shared.pdfData(snapshot(width: 3, height: 2, red: false)))
    }
}
