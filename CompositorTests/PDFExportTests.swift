import CoreGraphics
import Foundation
import ImageIO
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

    /// The page's image streams (its XObjects), read straight from the file rather than drawn.
    private func embeddedImages(_ page: CGPDFPage) throws -> [CGPDFStreamRef] {
        let dictionary = try #require(page.dictionary)
        var resources: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        var objects: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(try #require(resources), "XObject", &objects))
        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(try #require(objects), { _, value, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(value, .stream, &stream), let stream { streams.append(stream) }
            return true
        }, nil)
        return streams
    }

    private func size(of stream: CGPDFStreamRef) -> (Int, Int)? {
        guard let info = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(info, "Width", &width), CGPDFDictionaryGetInteger(info, "Height", &height) else { return nil }
        return (width, height)
    }

    /// The first pixel of a 4 × 4 color image stream: raw 8-bit RGB, or an encoded image ImageIO decodes.
    private func firstPixel(of stream: CGPDFStreamRef) -> (rgb: [Int], note: String)? {
        guard size(of: stream).map({ $0 == (4, 4) }) == true, let info = CGPDFStreamGetDictionary(stream) else { return nil }
        var bits: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(info, "BitsPerComponent", &bits)
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        let note = "format \(format.rawValue), \(bits) bits, \(data.count) bytes"
        if format == .raw {
            // The color image has three components a pixel; its transparency is a separate one-component mask.
            guard bits == 8, data.count == 16 * 3 else { return ([], note) }
            return (data.prefix(3).map(Int.init), note)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return ([], note) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return ([], note) }
        return ((0..<3).map { Int(bytes[$0]) }, note)
    }

    @Test func pageEmbedsTheImageUnresampled() async throws {
        let page = try pdfPage(await ImageExporter.shared.pdfData(snapshot(resolution: 288)))
        let sizes = try embeddedImages(page).compactMap(size)
        // A 1-point page still carries all 4 × 4 pixels.
        #expect(sizes.contains { $0 == (4, 4) }, "embedded images \(sizes)")
    }

    @Test func pageEmbedsTheImagesColors() async throws {
        let page = try pdfPage(await ImageExporter.shared.pdfData(snapshot()))
        let pixels = try embeddedImages(page).compactMap(firstPixel)
        #expect(pixels.contains { $0.rgb.count == 3 && $0.rgb[0] > 230 && $0.rgb[1] < 25 && $0.rgb[2] < 25 },
                "images \(pixels.map { "\($0.note), first \($0.rgb)" })")
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
