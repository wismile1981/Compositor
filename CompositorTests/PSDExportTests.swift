import AppKit
import Testing
@testable import Compositor

@MainActor
struct PSDExportTests {
    private func colorImage(width: Int = 2, height: Int = 2, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// Left half white (reveal), right half black (hide).
    private func halfMask(width: Int = 2, height: Int = 2) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return try #require(context.makeImage())
    }

    /// A pixel's value in sRGB (a gray mask reads as its brightness in every channel).
    private func value(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> CGFloat {
        try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)).redComponent
    }

    private func asset(_ image: CGImage, _ name: String) -> ImportedImage {
        ImportedImage(image: image, thumbnail: image, name: name)
    }

    private func record(_ id: UUID, _ name: String, origin: CGPoint = .zero, size: CGSize = CGSize(width: 2, height: 2),
                        rotation: CGFloat = 0, parentID: UUID? = nil, isGroup: Bool? = nil, opacity: Double? = nil,
                        blendMode: LayerBlendMode? = nil, hasMask: Bool = false, visible: Bool = true,
                        maskSourceID: UUID? = nil, adjustment: LayerAdjustment? = nil) -> ProjectLayerRecord {
        ProjectLayerRecord(id: id, name: name, isVisible: visible,
                           transform: LayerTransform(origin: origin, size: size, rotation: rotation, sampling: .nearest),
                           imageFile: isGroup == true || adjustment != nil ? nil : "\(id).png", parentID: parentID,
                           isGroup: isGroup, opacity: opacity, blendMode: blendMode,
                           maskFile: hasMask ? "\(id).mask.png" : nil, maskEnabled: hasMask ? true : nil,
                           maskSourceID: maskSourceID, adjustment: adjustment)
    }

    private func export(_ layers: [ProjectLayerRecord], images: [UUID: ImportedImage], masks: [UUID: ImportedImage] = [:],
                        width: Int = 6, height: Int = 6) async throws -> (document: PSDDocument, notes: [PSDConversion]) {
        var manifest = ProjectManifest(documentID: UUID(), width: width, height: height, activeLayerID: nil, layers: layers)
        manifest.resolution = 144
        let exported = try await ImageExporter.shared.psd(ProjectSnapshot(manifest: manifest, images: images, masks: masks))
        #expect(exported.data.prefix(4) == Data("8BPS".utf8))
        return (try PSDReader.read(exported.data), exported.notes)
    }

    @Test func layersKeepOrderVisibilityOpacityBlendAndPlacement() async throws {
        let (a, b) = (UUID(), UUID())
        let layers = [
            record(a, "Red", origin: CGPoint(x: 1, y: 1), size: CGSize(width: 4, height: 4), opacity: 0.5, blendMode: .multiply),
            record(b, "Blue", origin: CGPoint(x: 0, y: 0), blendMode: .linearDodge, visible: false)
        ]
        let images = [a: asset(try colorImage(red: 1, green: 0, blue: 0), "Red"),
                      b: asset(try colorImage(red: 0, green: 0, blue: 1), "Blue")]
        let (document, notes) = try await export(layers, images: images)
        #expect(notes.isEmpty)
        #expect(document.width == 6 && document.height == 6)
        #expect(document.resolution == 144)
        #expect(document.layers.map(\.name) == ["Red", "Blue"])
        #expect(document.layers[0].isVisible && !document.layers[1].isVisible)
        #expect(abs(document.layers[0].opacity - 0.5) < 0.01)
        #expect(document.layers[0].blendKey == "mul ")
        #expect(document.layers[1].blendKey == "lddg")
        // The 2 × 2 image scaled to 4 × 4 is baked to its size on the canvas.
        #expect(document.layers[0].bounds == CGRect(x: 1, y: 1, width: 4, height: 4))
        let bitmap = NSBitmapImageRep(cgImage: try #require(document.layers[0].image))
        #expect(bitmap.pixelsWide == 4 && bitmap.pixelsHigh == 4)
        #expect(try #require(bitmap.colorAt(x: 3, y: 3)).redComponent > 0.99)
        #expect(try #require(bitmap.colorAt(x: 3, y: 3)).alphaComponent > 0.99)
    }

    @Test func rotatedAndOffCanvasLayersAreBakedAndCropped() async throws {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let layers = [
            record(a, "Turned", origin: CGPoint(x: 1, y: 1), size: CGSize(width: 4, height: 2), rotation: 90),
            record(b, "Hanging", origin: CGPoint(x: -2, y: -2), size: CGSize(width: 4, height: 4)),
            record(c, "Gone", origin: CGPoint(x: 100, y: 100))
        ]
        let images = [a: asset(try colorImage(red: 1, green: 0, blue: 0), "A"),
                      b: asset(try colorImage(red: 0, green: 1, blue: 0), "B"),
                      c: asset(try colorImage(red: 0, green: 0, blue: 1), "C")]
        let (document, _) = try await export(layers, images: images)
        #expect(document.layers.count == 3)
        // 4 × 2 turned a quarter about its center (3, 2): 2 wide, 4 tall.
        #expect(document.layers[0].bounds == CGRect(x: 2, y: 0, width: 2, height: 4))
        // Only the part on the canvas is kept.
        #expect(document.layers[1].bounds == CGRect(x: 0, y: 0, width: 2, height: 2))
        // Nothing of the third is on the canvas: an empty layer keeps its place.
        #expect(document.layers[2].image == nil)
    }

    @Test func foldersNestAndKeepTheirOwnOpacity() async throws {
        let (folder, inner, outer) = (UUID(), UUID(), UUID())
        let layers = [
            record(folder, "Folder", isGroup: true, opacity: 0.5),
            record(inner, "Inner", parentID: folder, opacity: 0.8),
            record(outer, "Outer")
        ]
        let images = [inner: asset(try colorImage(red: 1, green: 0, blue: 0), "Inner"),
                      outer: asset(try colorImage(red: 0, green: 0, blue: 1), "Outer")]
        let (document, _) = try await export(layers, images: images)
        #expect(document.layers.map(\.name) == ["Inner", "Folder", "Outer"])
        let saved = try #require(document.layers.first { $0.name == "Folder" })
        #expect(saved.isGroup && abs(saved.opacity - 0.5) < 0.01)
        let child = try #require(document.layers.first { $0.name == "Inner" })
        #expect(child.parentID == saved.id && abs(child.opacity - 0.8) < 0.01)
        #expect(document.layers.first { $0.name == "Outer" }?.parentID == nil)
    }

    @Test func masksAreWrittenOnTheDocument() async throws {
        let id = UUID()
        let layers = [record(id, "Masked", origin: CGPoint(x: 1, y: 1), size: CGSize(width: 4, height: 4), hasMask: true)]
        let images = [id: asset(try colorImage(red: 1, green: 0, blue: 0), "Masked")]
        let masks = [id: asset(try halfMask(), "Mask")]
        let (document, notes) = try await export(layers, images: images, masks: masks)
        #expect(notes.isEmpty)
        let saved = try #require(document.layers.first)
        let mask = NSBitmapImageRep(cgImage: try #require(saved.mask))
        #expect(saved.maskBounds == CGRect(x: 1, y: 1, width: 4, height: 4))
        #expect(mask.pixelsWide == 4 && mask.pixelsHigh == 4)
        #expect(try value(mask, 0, 0) > 0.99)
        #expect(try value(mask, 3, 0) < 0.01)
    }

    @Test func clippingSurvivesOnlyOverItsBase() async throws {
        let (base, clipped, other, stray) = (UUID(), UUID(), UUID(), UUID())
        let layers = [
            record(base, "Base"),
            record(clipped, "Clipped", maskSourceID: base),
            record(other, "Other"),
            record(stray, "Stray", maskSourceID: base)
        ]
        let image = asset(try colorImage(red: 1, green: 0, blue: 0), "Red")
        let (document, notes) = try await export(layers, images: [base: image, clipped: image, other: image, stray: image])
        #expect(document.layers.map(\.clipping) == [false, true, false, false])
        // "Stray" no longer sits over its source, so it is written unclipped and reported.
        #expect(notes.map(\.layerName) == ["Stray"])
    }

    @Test func adjustmentsAreLeftOutAndReported() async throws {
        let (a, adjust) = (UUID(), UUID())
        let layers = [record(a, "Pixels"), record(adjust, "Invert", adjustment: LayerAdjustment(kind: .invert))]
        let (document, notes) = try await export(layers, images: [a: asset(try colorImage(red: 1, green: 0, blue: 0), "A")])
        #expect(document.layers.map(\.name) == ["Pixels"])
        #expect(notes.map(\.layerName) == ["Invert"])
    }

    @Test func nonASCIINamesSurviveThroughUnicodeName() async throws {
        let id = UUID()
        let (document, _) = try await export([record(id, "图层 1")], images: [id: asset(try colorImage(red: 1, green: 0, blue: 0), "A")])
        #expect(document.layers.first?.name == "图层 1")
    }

    @Test func everyBlendModeHasItsOwnKeyThatReadsBack() {
        var keys: Set<String> = []
        for mode in LayerBlendMode.allCases {
            #expect(mode.psdKey.count == 4)
            #expect(LayerBlendMode.fromPSD(mode.psdKey) == mode)
            keys.insert(mode.psdKey)
        }
        #expect(keys.count == LayerBlendMode.allCases.count)
    }

    @Test func emptyCanvasAndOversizedCanvas() async throws {
        let (document, notes) = try await export([], images: [:], width: 3, height: 2)
        #expect(document.layers.isEmpty && notes.isEmpty)
        #expect(document.width == 3 && document.height == 2)
        let huge = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: PSDWriter.maxSide + 1, height: 1,
                                                             activeLayerID: nil, layers: []), images: [:])
        await #expect(throws: (any Error).self) { try await ImageExporter.shared.psd(huge) }
    }
}
