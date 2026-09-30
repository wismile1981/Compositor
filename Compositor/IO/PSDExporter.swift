import CoreGraphics
import Foundation

nonisolated struct PSDExport: @unchecked Sendable {
    let data: Data
    /// What Photoshop can't hold as Compositor does, layer by layer.
    let notes: [PSDConversion]
}

/// A project as a layered Photoshop file. Compositor keeps a layer's pixels apart from its transform, which Photoshop
/// has no place for, so each layer is drawn into document space (cropped to the canvas) before it is written. Blend
/// mode, opacity, visibility, folders, masks and clipping carry over as Photoshop's own; what has no equivalent
/// (layer effects, adjustment layers, live masks, editable text) is flattened or left out, and reported.
nonisolated enum PSDExporter {
    static func export(_ snapshot: ProjectSnapshot, composite: ExportRaster) throws -> PSDExport {
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        guard (1...PSDWriter.maxSide).contains(width), (1...PSDWriter.maxSide).contains(height) else { throw ExportError.tooLarge }
        let records = snapshot.manifest.layers
        try LayerHierarchy.validate(records)
        for record in records {
            guard record.imageFile == nil || snapshot.images[record.id] != nil,
                  record.maskFile == nil || snapshot.masks[record.id] != nil else { throw ProjectError.missingImage }
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let children = Dictionary(grouping: records, by: \.parentID)
        var layers: [PSDWriter.Layer] = []
        var notes: [PSDConversion] = []

        func note(_ record: ProjectLayerRecord, _ message: String) {
            notes.append(PSDConversion(layerName: record.name, message: message))
        }

        func divider() -> PSDWriter.Layer {
            var layer = PSDWriter.Layer(name: "</Layer group>")
            layer.blocks = [PSDWriter.unicodeNameBlock(layer.name), PSDWriter.sectionBlock(type: 3, blendKey: "norm")]
            return layer
        }

        // A folder is pass-through in Compositor, and its opacity multiplies into what's inside, so it keeps its own
        // opacity and its layers keep theirs.
        func folder(_ record: ProjectLayerRecord) throws -> PSDWriter.Layer {
            var layer = PSDWriter.Layer(name: record.name, opacity: record.opacity ?? 1, blendKey: "pass",
                                        isVisible: record.isVisible)
            layer.blocks = [PSDWriter.unicodeNameBlock(record.name), PSDWriter.sectionBlock(type: 1, blendKey: "pass")]
            if let mask = snapshot.mask(for: record) {
                let size = CGSize(width: mask.asset.image.width, height: mask.asset.image.height)
                if let placed = try maskLayer(mask, transform: record.transform, grid: size, canvas: canvas) {
                    layer.mask = placed
                }
            }
            return layer
        }

        func pixelLayer(_ record: ProjectLayerRecord, clipped: Bool) throws -> PSDWriter.Layer {
            var layer = PSDWriter.Layer(name: record.name, opacity: record.opacity ?? 1,
                                        blendKey: (record.blendMode ?? .normal).psdKey, isClipping: clipped,
                                        isVisible: record.isVisible)
            layer.blocks = [PSDWriter.unicodeNameBlock(record.name)]
            guard let asset = snapshot.images[record.id] else { return layer }
            if record.text != nil { note(record, "Text was rasterized. It can’t be edited in Photoshop.") }
            let mask = snapshot.mask(for: record)
            var source = asset.image
            var transform = record.transform
            var exportsMask = mask != nil
            // Effects are drawn around the masked layer, so both go into the pixels together.
            let clip = mask.flatMap { $0.clipImage(placement: $0.placement, over: record.transform,
                                                     width: asset.image.width, height: asset.image.height) }
            if let effects = LayerEffectsRenderer.cached(asset.image, mask: clip, effects: record.effects) {
                source = effects.image
                transform = LayerEffectsRenderer.placed(record.transform, image: effects.image, inset: effects.inset)
                exportsMask = false
                note(record, "Layer effects\(mask?.isEnabled == true ? " and the layer mask" : "") were merged into the layer’s pixels.")
            }
            let rect = bounds(of: transform, in: canvas)
            guard let rect else { return layer }
            let context = try BrushRaster.context(width: Int(rect.width), height: Int(rect.height), mask: false)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            LayerRenderer.draw(source, transform: transform, center: transform.center, in: context)
            layer.channels = try PSDWriter.channels(of: context)
            layer.top = Int(rect.minY)
            layer.left = Int(rect.minX)
            layer.bottom = Int(rect.maxY)
            layer.right = Int(rect.maxX)
            if exportsMask, let mask {
                layer.mask = try maskLayer(mask, transform: record.transform,
                                           grid: CGSize(width: asset.image.width, height: asset.image.height), canvas: canvas,
                                           rect: rect)
            }
            return layer
        }

        func emit(_ parent: UUID?, depth: Int) throws {
            guard depth <= 64 else { throw ProjectError.invalid }
            // Photoshop clips a layer to the one below it that isn't clipped itself.
            var base: UUID?
            for record in children[parent] ?? [] {
                try Task.checkCancellation()
                if record.isGroup == true {
                    layers.append(divider())
                    try emit(record.id, depth: depth + 1)
                    layers.append(try folder(record))
                    base = nil
                    continue
                }
                if record.adjustment != nil {
                    note(record, "Adjustment layers aren’t written to Photoshop files. Their effect is in the flattened preview only.")
                    continue
                }
                var clipped = false
                if let source = record.maskSourceID {
                    if source == base { clipped = true }
                    else { note(record, "A live mask from another layer isn’t supported, so the layer was written without it.") }
                }
                if !clipped { base = record.id }
                layers.append(try pixelLayer(record, clipped: clipped))
            }
        }

        try emit(nil, depth: 0)
        let data = try PSDWriter.data(width: width, height: height, resolution: snapshot.manifest.resolution ?? 72,
                                      layers: layers, composite: composite.image,
                                      iccProfile: CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?)
        return PSDExport(data: data, notes: notes)
    }

    /// Where a layer's transformed rectangle lands on the canvas, in whole pixels; nil when none of it does.
    static func bounds(of transform: LayerTransform, in canvas: CGRect) -> CGRect? {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(transform.point)
        guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max() else { return nil }
        // Turning a layer a quarter leaves rounding dust (1.9999999999999998) that would grow the box by a pixel.
        func snapped(_ value: CGFloat) -> CGFloat { (value * 1e6).rounded() / 1e6 }
        let visible = CGRect(x: snapped(minX), y: snapped(minY), width: snapped(maxX) - snapped(minX),
                             height: snapped(maxY) - snapped(minY)).intersection(canvas)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        let whole = visible.integral.intersection(canvas)
        return whole.width >= 1 && whole.height >= 1 ? whole : nil
    }

    /// A mask drawn over `rect` on the document (the whole placed rectangle, cropped to the canvas, when nil).
    /// `grid` is the pixel size of the layer the mask stretches over.
    private static func maskLayer(_ mask: LayerMask, transform: LayerTransform, grid: CGSize, canvas: CGRect,
                                  rect: CGRect? = nil) throws -> PSDWriter.Mask? {
        guard let rect = rect ?? bounds(of: transform, in: canvas) else { return nil }
        var enabled = mask
        enabled.isEnabled = true
        guard let image = enabled.clipImage(placement: mask.placement, over: transform,
                                            width: max(1, Int(grid.width)), height: max(1, Int(grid.height))) else { return nil }
        let context = try BrushRaster.context(width: Int(rect.width), height: Int(rect.height), mask: true)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        LayerRenderer.drawCoverage(image, transform: transform, in: context)
        let background = LayerMask.background(of: mask.asset.thumbnail)
        return PSDWriter.Mask(top: Int(rect.minY), left: Int(rect.minX), bottom: Int(rect.maxY), right: Int(rect.maxX),
                              defaultColor: background >= 0.5 ? 255 : 0, isEnabled: mask.isEnabled,
                              payload: try PSDWriter.maskPayload(of: context))
    }
}

extension ImageExporter {
    func psd(_ snapshot: ProjectSnapshot) throws -> PSDExport {
        let raster = try render(snapshot)
        return try PSDExporter.export(snapshot, composite: raster)
    }
}
