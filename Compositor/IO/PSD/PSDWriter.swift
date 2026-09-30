import CoreGraphics
import Foundation

/// Writes 8-bit RGB Photoshop files (PSD, or PSB when `largeDocument`) after Adobe’s 2019 Photoshop File Formats
/// Specification: layers with masks, folders, blend modes and clipping, a resolution, an embedded profile and a
/// flattened preview. Layer pixels arrive already encoded (`channels(of:)`), so a caller can encode one layer at a
/// time and let go of its pixels before the next.
nonisolated enum PSDWriter {
    /// A layer mask, in document coordinates. `payload` is its channel data (`channelPayload`).
    nonisolated struct Mask: Sendable {
        var top = 0, left = 0, bottom = 0, right = 0
        /// What the mask shows beyond its rectangle.
        var defaultColor: UInt8 = 255
        var isEnabled = true
        var isLinked = true
        var payload = Data()
    }

    /// One layer record, bottom to top in file order. Folders are two records: a divider first, then the folder
    /// itself after everything inside it (see `sectionBlock`).
    nonisolated struct Layer: @unchecked Sendable {
        var name: String
        var top = 0, left = 0, bottom = 0, right = 0
        var opacity = 1.0
        var blendKey = "norm"
        var isClipping = false
        var isVisible = true
        var channels: [(id: Int16, payload: Data)] = PSDWriter.emptyChannels
        var mask: Mask?
        /// Additional layer information, written in this order after the name.
        var blocks: [(key: String, payload: Data)] = []
    }

    static let maxSide = 30_000

    static let emptyChannels: [(id: Int16, payload: Data)] = [
        (id: -1, payload: Data([0, 0])), (id: 0, payload: Data([0, 0])),
        (id: 1, payload: Data([0, 0])), (id: 2, payload: Data([0, 0]))
    ]

    static func data(width: Int, height: Int, resolution: Double, layers: [Layer], composite: CGImage,
                     largeDocument: Bool = false, iccProfile: Data? = nil) throws -> Data {
        guard (1...maxSide).contains(width), (1...maxSide).contains(height),
              layers.count <= Int(Int16.max) else { throw ImageImportError.tooLarge }
        var file = PSDByteWriter()
        file.string("8BPS")
        file.u16(largeDocument ? 2 : 1)
        file.bytes(Data(count: 6))
        file.u16(4)
        file.u32(UInt32(height))
        file.u32(UInt32(width))
        file.u16(8)
        file.u16(3)
        file.u32(0)
        let resources = imageResources(resolution: resolution, iccProfile: iccProfile)
        file.u32(UInt32(resources.count))
        file.bytes(resources)
        let section = layerSection(layers, largeDocument: largeDocument)
        if largeDocument { file.u64(UInt64(section.count)) }
        else {
            guard section.count <= Int(UInt32.max) else { throw ImageImportError.tooLarge }
            file.u32(UInt32(section.count))
        }
        file.bytes(section)
        try appendComposite(&file, composite, width: width, height: height, largeDocument: largeDocument)
        return file.data
    }

    // MARK: Layers

    private static func layerSection(_ layers: [Layer], largeDocument: Bool) -> Data {
        var records = PSDByteWriter()
        // A negative count tells Photoshop the merged image's first extra channel is its transparency, not an alpha
        // channel to list in the Channels panel.
        records.i16(-Int16(layers.count))
        var payloads = PSDByteWriter()
        for layer in layers {
            var channels = layer.channels
            if let mask = layer.mask { channels.append((id: -2, payload: mask.payload)) }
            writeRecord(&records, layer, channels: channels, largeDocument: largeDocument)
            for channel in channels { payloads.bytes(channel.payload) }
        }
        var info = records.data
        info.append(payloads.data)
        while info.count % 4 != 0 { info.append(0) }
        var section = PSDByteWriter()
        if largeDocument { section.u64(UInt64(info.count)) }
        else { section.u32(UInt32(info.count)) }
        section.bytes(info)
        section.u32(0)
        return section.data
    }

    private static func writeRecord(_ buffer: inout PSDByteWriter, _ layer: Layer, channels: [(id: Int16, payload: Data)],
                                    largeDocument: Bool) {
        buffer.i32(Int32(clamping: layer.top))
        buffer.i32(Int32(clamping: layer.left))
        buffer.i32(Int32(clamping: layer.bottom))
        buffer.i32(Int32(clamping: layer.right))
        buffer.u16(UInt16(channels.count))
        for channel in channels {
            buffer.i16(channel.id)
            if largeDocument { buffer.u64(UInt64(channel.payload.count)) }
            else { buffer.u32(UInt32(channel.payload.count)) }
        }
        buffer.string("8BIM")
        buffer.string(String((layer.blendKey + "    ").prefix(4)))
        buffer.u8(UInt8(clamping: Int((min(1, max(0, layer.opacity)) * 255).rounded())))
        buffer.u8(layer.isClipping ? 1 : 0)
        // Bit 1 hides the layer.
        buffer.u8(layer.isVisible ? 0 : 2)
        buffer.u8(0)
        let extra = extraData(layer, largeDocument: largeDocument)
        buffer.u32(UInt32(extra.count))
        buffer.bytes(extra)
    }

    private static func extraData(_ layer: Layer, largeDocument: Bool) -> Data {
        var extra = PSDByteWriter()
        if let mask = layer.mask, mask.right > mask.left, mask.bottom > mask.top {
            extra.u32(20)
            extra.i32(Int32(clamping: mask.top))
            extra.i32(Int32(clamping: mask.left))
            extra.i32(Int32(clamping: mask.bottom))
            extra.i32(Int32(clamping: mask.right))
            extra.u8(mask.defaultColor)
            var flags: UInt8 = mask.isLinked ? 0 : 1
            if !mask.isEnabled { flags |= 2 }
            extra.u8(flags)
            extra.u16(0)
        } else {
            extra.u32(0)
        }
        // Layer blending ranges: none.
        extra.u32(0)
        // The Pascal name, padded to four bytes. Photoshop reads the real name from `luni`, so anything outside
        // ASCII is only a placeholder here.
        let ascii = layer.name.unicodeScalars.map { $0.value < 128 && $0.value >= 32 ? UInt8($0.value) : UInt8(ascii: "_") }
        let pascal = Array(ascii.prefix(255))
        extra.u8(UInt8(pascal.count))
        extra.bytes(Data(pascal))
        extra.bytes(Data(count: (4 - (1 + pascal.count) % 4) % 4))
        for block in layer.blocks {
            writeBlock(&extra, key: block.key, payload: block.payload, largeDocument: largeDocument)
        }
        return extra.data
    }

    private static let largeBlockKeys: Set<String> = [
        "LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"
    ]

    private static func writeBlock(_ buffer: inout PSDByteWriter, key: String, payload: Data, largeDocument: Bool) {
        buffer.string("8BIM")
        buffer.string(key)
        if largeDocument && largeBlockKeys.contains(key) { buffer.u64(UInt64(payload.count)) }
        else { buffer.u32(UInt32(payload.count)) }
        buffer.bytes(payload)
        if payload.count % 2 == 1 { buffer.u8(0) }
    }

    /// `luni`: the layer's name in Unicode, padded to four bytes as Photoshop writes it.
    static func unicodeNameBlock(_ name: String) -> (key: String, payload: Data) {
        let units = Array(name.utf16)
        var payload = PSDByteWriter()
        payload.u32(UInt32(units.count))
        for unit in units { payload.u16(unit) }
        while payload.data.count % 4 != 0 { payload.u8(0) }
        return (key: "luni", payload: payload.data)
    }

    /// `lsct`: what a folder's two records are. Type 1 is an open folder, 3 the divider that ends it.
    static func sectionBlock(type: UInt32, blendKey: String) -> (key: String, payload: Data) {
        var payload = PSDByteWriter()
        payload.u32(type)
        payload.string("8BIM")
        payload.string(String((blendKey + "    ").prefix(4)))
        return (key: "lsct", payload: payload.data)
    }

    // MARK: Pixels

    /// Alpha, red, green and blue channel data for a layer whose pixels sit in `context` (premultiplied RGBA, as
    /// `BrushRaster.context` makes it).
    static func channels(of context: CGContext, largeDocument: Bool = false) throws -> [(id: Int16, payload: Data)] {
        let planes = try planes(of: context)
        let width = context.width, height = context.height
        func payload(_ plane: [UInt8]) -> Data {
            channelPayload(plane, width: width, height: height, largeDocument: largeDocument)
        }
        return [(id: -1, payload: payload(planes.alpha)), (id: 0, payload: payload(planes.red)),
                (id: 1, payload: payload(planes.green)), (id: 2, payload: payload(planes.blue))]
    }

    static func channels(of image: CGImage, largeDocument: Bool = false) throws -> [(id: Int16, payload: Data)] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return try channels(of: context, largeDocument: largeDocument)
    }

    /// Channel data for one 8-bit plane: a compression code (PackBits) and its rows.
    static func channelPayload(_ plane: [UInt8], width: Int, height: Int, largeDocument: Bool = false) -> Data {
        let encoded = encode(plane, width: width, height: height, largeDocument: largeDocument)
        var data = Data([UInt8(encoded.compression >> 8), UInt8(encoded.compression & 0xff)])
        data.append(encoded.data)
        return data
    }

    /// A mask's channel data from a `width` × `height` gray plane.
    static func maskPayload(of context: CGContext, largeDocument: Bool = false) throws -> Data {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        let width = context.width, height = context.height, stride = context.bytesPerRow
        var plane = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { plane[y * width + x] = data[y * stride + x] }
        }
        return channelPayload(plane, width: width, height: height, largeDocument: largeDocument)
    }

    static func maskPayload(of image: CGImage, largeDocument: Bool = false) throws -> Data {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: true, context: context)
        return try maskPayload(of: context, largeDocument: largeDocument)
    }

    /// Straight (not premultiplied) planes, first row at the top.
    private static func planes(of context: CGContext) throws -> (red: [UInt8], green: [UInt8], blue: [UInt8], alpha: [UInt8]) {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        let width = context.width, height = context.height, stride = context.bytesPerRow
        var red = [UInt8](repeating: 0, count: width * height)
        var green = [UInt8](repeating: 0, count: width * height)
        var blue = [UInt8](repeating: 0, count: width * height)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let p = y * stride + x * 4
                let r = Int(data[p]), g = Int(data[p + 1]), b = Int(data[p + 2]), a = Int(data[p + 3])
                alpha[i] = UInt8(a)
                guard a > 0 else { continue }
                red[i] = UInt8(min(255, (r * 255 + a / 2) / a))
                green[i] = UInt8(min(255, (g * 255 + a / 2) / a))
                blue[i] = UInt8(min(255, (b * 255 + a / 2) / a))
            }
        }
        return (red, green, blue, alpha)
    }

    private static func encode(_ plane: [UInt8], width: Int, height: Int, largeDocument: Bool) -> (compression: UInt16, data: Data) {
        guard width > 0, height > 0, plane.count >= width * height else { return (0, Data()) }
        var counts = Data()
        var packed = Data()
        counts.reserveCapacity(height * (largeDocument ? 4 : 2))
        for row in 0..<height {
            let encoded = packBits(plane[row * width ..< (row + 1) * width])
            if largeDocument {
                counts.append(UInt8(truncatingIfNeeded: encoded.count >> 24))
                counts.append(UInt8(truncatingIfNeeded: encoded.count >> 16))
            }
            counts.append(UInt8(truncatingIfNeeded: encoded.count >> 8))
            counts.append(UInt8(truncatingIfNeeded: encoded.count))
            packed.append(encoded)
        }
        var data = counts
        data.append(packed)
        return (1, data)
    }

    private static func packBits(_ row: ArraySlice<UInt8>) -> Data {
        var output = Data()
        var i = row.startIndex
        while i < row.endIndex {
            if i + 1 < row.endIndex, row[i] == row[i + 1] {
                var run = 2
                while i + run < row.endIndex, row[i + run] == row[i], run < 128 { run += 1 }
                output.append(UInt8(bitPattern: Int8(1 - run)))
                output.append(row[i])
                i += run
            } else {
                let start = i
                i += 1
                while i < row.endIndex, i - start < 128 {
                    if i + 1 < row.endIndex, row[i] == row[i + 1] { break }
                    i += 1
                }
                output.append(UInt8(i - start - 1))
                output.append(contentsOf: row[start..<i])
            }
        }
        return output
    }

    // MARK: Document

    private static func imageResources(resolution: Double, iccProfile: Data?) -> Data {
        var resources = PSDByteWriter()
        let fixed = UInt32((min(9600, max(1, resolution)) * 65536).rounded())
        var payload = PSDByteWriter()
        // Horizontal and vertical resolution in pixels per inch, then their display unit and the size unit.
        payload.u32(fixed)
        payload.u16(1)
        payload.u16(1)
        payload.u32(fixed)
        payload.u16(1)
        payload.u16(1)
        appendResource(&resources, id: 1005, payload: payload.data)
        // The embedded profile, so Photoshop doesn't ask what an untagged file means.
        if let iccProfile, !iccProfile.isEmpty { appendResource(&resources, id: 1039, payload: iccProfile) }
        return resources.data
    }

    private static func appendResource(_ buffer: inout PSDByteWriter, id: UInt16, payload: Data) {
        buffer.string("8BIM")
        buffer.u16(id)
        buffer.u8(0)
        buffer.u8(0)
        buffer.u32(UInt32(payload.count))
        buffer.bytes(payload)
        if payload.count % 2 == 1 { buffer.u8(0) }
    }

    /// The flattened image every reader shows without layers, with its transparency as the fourth channel.
    private static func appendComposite(_ file: inout PSDByteWriter, _ image: CGImage, width: Int, height: Int,
                                        largeDocument: Bool) throws {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        let planes = try planes(of: context)
        file.u16(1)
        var counts = Data()
        var packed = Data()
        for plane in [planes.red, planes.green, planes.blue, planes.alpha] {
            let encoded = encode(plane, width: width, height: height, largeDocument: largeDocument)
            let countBytes = height * (largeDocument ? 4 : 2)
            counts.append(encoded.data.prefix(countBytes))
            packed.append(encoded.data.dropFirst(countBytes))
        }
        file.bytes(counts)
        file.bytes(packed)
    }
}

nonisolated struct PSDByteWriter: Sendable {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) {
        u16(UInt16(truncatingIfNeeded: value >> 16))
        u16(UInt16(truncatingIfNeeded: value))
    }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value >> 32))
        u32(UInt32(truncatingIfNeeded: value))
    }
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func string(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
}

extension LayerBlendMode {
    /// The four-character blend key Photoshop files use; the reverse of `fromPSD`.
    nonisolated var psdKey: String {
        switch self {
        case .normal: "norm"
        case .multiply: "mul "
        case .screen: "scrn"
        case .overlay: "over"
        case .softLight: "sLit"
        case .darken: "dark"
        case .lighten: "lite"
        case .difference: "diff"
        case .colorDodge: "div "
        case .colorBurn: "idiv"
        case .hue: "hue "
        case .saturation: "sat "
        case .color: "colr"
        case .luminosity: "lum "
        case .linearBurn: "lbrn"
        case .linearDodge: "lddg"
        case .hardLight: "hLit"
        case .vividLight: "vLit"
        case .linearLight: "lLit"
        case .pinLight: "pLit"
        case .hardMix: "hMix"
        case .exclusion: "smud"
        case .subtract: "fsub"
        case .divide: "fdiv"
        }
    }
}
