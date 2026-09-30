import CoreGraphics
import Foundation
@testable import Compositor

/// Builds tiny Photoshop files for reader tests: `PSDWriter` writes the file, and this lays a `PSDDocument` out as its
/// layers. It also builds layer blocks (`TySh`) the app doesn't write.
nonisolated enum PSDFixture {
    static func data(_ document: PSDDocument, composite: CGImage, largeDocument: Bool = false,
                     extras: [UUID: [String: Data]] = [:]) throws -> Data {
        try data(document, composite: composite, largeDocument: largeDocument, additionalLayerInfo: nil, extras: extras)
    }

    struct AdditionalLayerInfo: Sendable {
        let key: String
        let payload: Data
    }

    static func data(_ document: PSDDocument, composite: CGImage, largeDocument: Bool, additionalLayerInfo: AdditionalLayerInfo?,
                     extras: [UUID: [String: Data]] = [:]) throws -> Data {
        var layers: [PSDWriter.Layer] = []
        func blocks(_ record: PSDRecord, lsct: (key: String, payload: Data)? = nil) -> [(key: String, payload: Data)] {
            var result: [(key: String, payload: Data)] = []
            if let additionalLayerInfo { result.append((key: additionalLayerInfo.key, payload: additionalLayerInfo.payload)) }
            result.append(PSDWriter.unicodeNameBlock(record.name))
            if let lsct { result.append(lsct) }
            let own = extras[record.id] ?? [:]
            for key in own.keys.sorted() {
                if let payload = own[key] { result.append((key: key, payload: payload)) }
            }
            return result
        }
        // File order is bottom-to-top. Photoshop groups are type 3, children, then type 1/2.
        func emit(_ parent: UUID?) throws {
            for record in document.layers where record.parentID == parent {
                if record.isGroup {
                    let divider = PSDRecord(id: UUID(), parentID: parent, name: "</Layer group>")
                    var end = PSDWriter.Layer(name: divider.name)
                    end.blocks = blocks(divider, lsct: PSDWriter.sectionBlock(type: 3, blendKey: "norm"))
                    layers.append(end)
                    try emit(record.id)
                    var folder = PSDWriter.Layer(name: record.name, opacity: record.opacity, blendKey: record.blendKey,
                                                 isVisible: record.isVisible)
                    folder.blocks = blocks(record, lsct: PSDWriter.sectionBlock(type: 1, blendKey: record.blendKey))
                    if let mask = record.mask {
                        folder.mask = PSDWriter.Mask(top: 0, left: 0, bottom: mask.height, right: mask.width,
                                                     isEnabled: record.maskEnabled, isLinked: record.maskLinked,
                                                     payload: try PSDWriter.maskPayload(of: mask, largeDocument: largeDocument))
                    }
                    layers.append(folder)
                } else {
                    layers.append(try layer(record, blocks: blocks(record), largeDocument: largeDocument))
                }
            }
        }
        try emit(nil)
        return try PSDWriter.data(width: document.width, height: document.height, resolution: document.resolution,
                                  layers: layers, composite: composite, largeDocument: largeDocument)
    }

    private static func layer(_ record: PSDRecord, blocks: [(key: String, payload: Data)], largeDocument: Bool) throws -> PSDWriter.Layer {
        let left = Int(record.bounds.minX.rounded())
        let top = Int(record.bounds.minY.rounded())
        var layer = PSDWriter.Layer(name: record.name, top: top, left: left, opacity: record.opacity,
                                    blendKey: record.blendKey, isClipping: record.clipping, isVisible: record.isVisible)
        if let image = record.image, image.width > 0, image.height > 0 {
            layer.channels = try PSDWriter.channels(of: image, largeDocument: largeDocument)
            layer.bottom = top + image.height
            layer.right = left + image.width
        }
        if let mask = record.mask {
            layer.mask = PSDWriter.Mask(top: top, left: left, bottom: top + mask.height, right: left + mask.width,
                                        isEnabled: record.maskEnabled, isLinked: record.maskLinked,
                                        payload: try PSDWriter.maskPayload(of: mask, largeDocument: largeDocument))
        }
        layer.blocks = blocks
        return layer
    }

    /// A Photoshop 6 `TySh` block. The descriptor layout matches Adobe’s type-tool object setting.
    static func tySh(text: String, font: String = "Helvetica", fontSize: Double = 24,
                     red: Double = 0, green: Double = 0, blue: Double = 0,
                     justification: Int = 0, tracking: Double = 0, leading: Double? = nil,
                     fauxBold: Bool = false, fauxItalic: Bool = false, vertical: Bool = false, warp: Bool = false,
                     secondSize: Double? = nil, secondLeading: Double? = nil,
                     secondHorizontalScale: Double? = nil, secondVerticalScale: Double? = nil,
                     tx: Double = 40, ty: Double = 50,
                     xx: Double = 1, xy: Double = 0, yx: Double = 0, yy: Double = 1,
                     bounds: (CGFloat, CGFloat, CGFloat, CGFloat)? = nil,
                     glyphBounds: (CGFloat, CGFloat, CGFloat, CGFloat)? = nil) -> Data {
        var block = PSDBuffer()
        block.u16(1)
        for value in [xx, xy, yx, yy, tx, ty] { block.f64(value) }
        block.u16(50)
        var items: [(String, Data)] = [
            ("Txt ", textItem(text)),
            ("Ornt", enumItem(type: "Ornt", value: vertical ? "Vrtc" : "Hrzn"))
        ]
        if let bounds {
            items.append(("bounds", rectItem(bounds)))
        }
        if let glyphBounds {
            items.append(("boundingBox", rectItem(glyphBounds)))
        }
        items.append(("EngineData", rawItem(Data(engine(text: text, font: font, fontSize: fontSize, red: red, green: green, blue: blue, justification: justification, tracking: tracking, leading: leading, fauxBold: fauxBold, fauxItalic: fauxItalic, secondSize: secondSize, secondLeading: secondLeading, secondHorizontalScale: secondHorizontalScale, secondVerticalScale: secondVerticalScale).utf8))))
        block.descriptor(classID: "TxLr", items: items)
        block.u16(1)
        block.descriptor(classID: "warp", items: [("warpStyle", enumItem(type: "warpStyle", value: warp ? "warpArc" : "warpNone"))])
        return block.data
    }

    private static func engine(text: String, font: String, fontSize: Double, red: Double, green: Double, blue: Double, justification: Int, tracking: Double, leading: Double?, fauxBold: Bool, fauxItalic: Bool, secondSize: Double?, secondLeading: Double?, secondHorizontalScale: Double?, secondVerticalScale: Double?) -> String {
        let run = { (size: Double, runLeading: Double?, horizontal: Double, vertical: Double) in """
<<
/StyleSheet
<<
/StyleSheetData
<<
/Font 0
/FontSize \(size)
/FauxBold \(fauxBold)
/FauxItalic \(fauxItalic)
/AutoLeading \(runLeading == nil)
/Leading \(runLeading ?? size * 1.2)
/Tracking \(tracking)
/HorizontalScale \(horizontal)
/VerticalScale \(vertical)
/FillColor
<<
/Type 1
/Values [ 1.0 \(red) \(green) \(blue) ]
>>
>>
>>
>>
""" }
        let hasSecond = secondSize != nil || secondLeading != nil || secondHorizontalScale != nil || secondVerticalScale != nil
        let runs = hasSecond
            ? "\(run(fontSize, leading, 1, 1))\n\(run(secondSize ?? fontSize, secondLeading ?? leading, secondHorizontalScale ?? 1, secondVerticalScale ?? 1))"
            : run(fontSize, leading, 1, 1)
        return """
<<
/EngineDict
<<
/Editor
<<
/Text \(parenthesized(text))
>>
/ParagraphRun
<<
/RunArray
[
<<
/ParagraphSheet
<<
/Properties
<<
/Justification \(justification)
>>
>>
>>
]
>>
/StyleRun
<<
/RunArray
[
\(runs)
]
>>
>>
/ResourceDict
<<
/FontSet
[
<<
/Name \(parenthesized(font))
>>
]
>>
>>
"""
    }

    private static func parenthesized(_ text: String) -> String {
        var encoded = "("
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\\") || byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") {
                encoded.append("\\")
            }
            encoded.append(Character(UnicodeScalar(byte)))
        }
        encoded.append(")")
        return encoded
    }

    private static func textItem(_ text: String) -> Data {
        var item = PSDBuffer()
        item.string("TEXT")
        item.utf16(text)
        return item.data
    }

    private static func enumItem(type: String, value: String) -> Data {
        var item = PSDBuffer()
        item.string("enum")
        item.id(type)
        item.id(value)
        return item.data
    }

    private static func rawItem(_ payload: Data) -> Data {
        var item = PSDBuffer()
        item.string("tdta")
        item.u32(UInt32(payload.count))
        item.bytes(payload)
        return item.data
    }

    private static func rectItem(_ box: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Data {
        var item = PSDBuffer()
        item.string("Objc")
        item.u32(0)
        item.id("Rctn")
        item.u32(4)
        for (key, value) in [("Left", box.0), ("Top ", box.1), ("Rght", box.2), ("Btom", box.3)] {
            item.id(key)
            item.string("UntF")
            item.string("#Pnt")
            item.f64(Double(value))
        }
        return item.data
    }
}

nonisolated private struct PSDBuffer: Sendable {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { data.appendUInt16(value) }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) { data.appendUInt32(value) }
    mutating func u64(_ value: UInt64) { data.appendUInt64(value) }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func f64(_ value: Double) {
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func string(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
    mutating func utf16(_ value: String) {
        let units = Array(value.utf16)
        u32(UInt32(units.count))
        for unit in units { u16(unit) }
    }
    mutating func id(_ value: String) {
        let bytes = Array(value.utf8)
        if bytes.count == 4 {
            u32(0)
            data.append(contentsOf: bytes)
        } else {
            u32(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }
    }
    mutating func descriptor(classID: String, items: [(String, Data)]) {
        u32(16)
        u32(0)
        id(classID)
        u32(UInt32(items.count))
        for (key, value) in items {
            id(key)
            bytes(value)
        }
    }
}

extension Data {
    fileprivate mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    fileprivate mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    fileprivate mutating func appendUInt64(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value >> 56))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
