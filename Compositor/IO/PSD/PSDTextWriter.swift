import AppKit
import CoreGraphics
import Foundation

/// What only text layout can say about a rendered text layer, measured before export because TextKit belongs on the
/// main actor: where the text is anchored in the layer's own pixels, and how far the letters reach.
nonisolated struct PSDTextLayout: Sendable {
    /// The frame's top-left for a paragraph box, otherwise where the first line's baseline starts.
    var anchor: CGPoint
    /// The letters' extent.
    var glyphs: CGRect
}

/// A Photoshop 6 type layer (`TySh`), the reverse of `PSDText.parse`: a transform, a text descriptor carrying the
/// text and its engine data, and a warp descriptor. Sizes are written in document pixels with the matrix at unit
/// scale, which is how `PSDText` reads them back.
nonisolated enum PSDTextWriter {
    @MainActor
    static func layouts(for snapshot: ProjectSnapshot) -> [UUID: PSDTextLayout] {
        var result: [UUID: PSDTextLayout] = [:]
        for record in snapshot.manifest.layers {
            guard let style = record.text, style.isValid, let image = snapshot.images[record.id]?.image else { continue }
            result[record.id] = layout(style, imageSize: CGSize(width: image.width, height: image.height))
        }
        return result
    }

    @MainActor
    static func layout(_ style: LayerTextStyle, imageSize: CGSize) -> PSDTextLayout {
        let padding = LayerTextStyle.padding
        let storage = NSTextStorage(attributedString: EditorSession.attributedText(style))
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, imageSize.width - 2 * padding),
                                                     height: max(1, imageSize.height - 2 * padding)))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let glyphRange = manager.glyphRange(for: container)
        let used = manager.usedRect(for: container).offsetBy(dx: padding, dy: padding)
        if style.boxSize != nil { return PSDTextLayout(anchor: CGPoint(x: padding, y: padding), glyphs: used) }
        let x: CGFloat
        switch style.alignment {
        case .left: x = padding
        case .center: x = imageSize.width / 2
        case .right: x = imageSize.width - padding
        }
        var baseline = padding + style.fontSize * 0.8
        if glyphRange.length > 0 {
            let fragment = manager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            baseline = padding + fragment.minY + manager.location(forGlyphAt: glyphRange.location).y
        }
        return PSDTextLayout(anchor: CGPoint(x: x, y: baseline), glyphs: used)
    }

    /// The `TySh` payload for `style`, drawn `scale` document pixels per layer pixel and turned `rotation` degrees
    /// clockwise, its anchor landing on `documentAnchor`.
    static func tySh(style: LayerTextStyle, scale: Double, rotation: Double, documentAnchor: CGPoint,
                     layout: PSDTextLayout) -> Data {
        let radians = rotation * .pi / 180
        let padding = Double(LayerTextStyle.padding)
        let glyphs = layout.glyphs
        let bounds: (Double, Double, Double, Double)
        let glyphBox: (Double, Double, Double, Double)
        if let box = style.boxSize {
            bounds = (0, 0, (Double(box.width) - padding * 2) * scale, (Double(box.height) - padding * 2) * scale)
            glyphBox = ((Double(glyphs.minX) - padding) * scale, (Double(glyphs.minY) - padding) * scale,
                        (Double(glyphs.maxX) - padding) * scale, (Double(glyphs.maxY) - padding) * scale)
        } else {
            glyphBox = ((Double(glyphs.minX) - Double(layout.anchor.x)) * scale, (Double(glyphs.minY) - Double(layout.anchor.y)) * scale,
                        (Double(glyphs.maxX) - Double(layout.anchor.x)) * scale, (Double(glyphs.maxY) - Double(layout.anchor.y)) * scale)
            bounds = glyphBox
        }
        var block = PSDByteWriter()
        block.u16(1)
        for value in [cos(radians), -sin(radians), sin(radians), cos(radians), Double(documentAnchor.x), Double(documentAnchor.y)] {
            block.f64(value)
        }
        block.u16(50)
        block.descriptor(classID: "TxLr", items: [
            ("Txt ", textItem(style.content.replacingOccurrences(of: "\n", with: "\r"))),
            ("textGridding", enumItem(type: "textGridding", value: "None")),
            ("Ornt", enumItem(type: "Ornt", value: "Hrzn")),
            ("AntA", enumItem(type: "Annt", value: "AnSm")),
            ("bounds", rectItem(bounds)),
            ("boundingBox", rectItem(glyphBox)),
            ("TextIndex", longItem(0)),
            ("EngineData", rawItem(engineData(style: style, scale: scale)))
        ])
        block.u16(1)
        block.descriptor(classID: "warp", items: [
            ("warpStyle", enumItem(type: "warpStyle", value: "warpNone")),
            ("warpValue", doubleItem(0)),
            ("warpPerspective", doubleItem(0)),
            ("warpPerspectiveOther", doubleItem(0)),
            ("warpRotate", enumItem(type: "Ornt", value: "Hrzn"))
        ])
        for value in [bounds.0, bounds.1, bounds.2, bounds.3] { block.f64(value) }
        while block.data.count % 4 != 0 { block.u8(0) }
        return block.data
    }

    // MARK: Engine data

    /// Photoshop's text-engine dictionary: the text with its paragraph terminator, one paragraph run per paragraph
    /// and one style run per stretch of letters that share a face and a color.
    static func engineData(style: LayerTextStyle, scale: Double) -> Data {
        let units = Array(style.content.utf16).map { $0 == 10 ? UInt16(13) : $0 }
        let size = Double(style.fontSize) * scale
        var fonts = [style.fontName]
        func fontIndex(_ name: String) -> Int {
            if let index = fonts.firstIndex(of: name) { return index }
            fonts.append(name)
            return fonts.count - 1
        }
        struct Segment { var font: Int; var color: (Double, Double, Double); var length: Int }
        var segments: [Segment] = []
        let fontRuns = style.fontRuns ?? [], colorRuns = style.colorRuns ?? []
        for position in 0..<units.count {
            let font = fontRuns.first { position >= $0.location && position < $0.location + $0.length }
                .map { fontIndex($0.fontName) } ?? 0
            let run = colorRuns.first { position >= $0.location && position < $0.location + $0.length }
            let color = run.map { (Double($0.red), Double($0.green), Double($0.blue)) }
                ?? (Double(style.red), Double(style.green), Double(style.blue))
            if let last = segments.last, last.font == font, last.color == color { segments[segments.count - 1].length += 1 }
            else { segments.append(Segment(font: font, color: color, length: 1)) }
        }
        if segments.isEmpty { segments = [Segment(font: 0, color: (Double(style.red), Double(style.green), Double(style.blue)), length: 0)] }
        // The paragraph terminator takes the last letters' style.
        segments[segments.count - 1].length += 1
        var paragraphLengths: [Int] = []
        var current = 0
        for unit in units {
            current += 1
            if unit == 13 { paragraphLengths.append(current); current = 0 }
        }
        paragraphLengths.append(current + 1)
        let justification = style.alignment == .left ? 0 : style.alignment == .right ? 1 : 2
        let tracking = style.fontSize > 0 ? Double(style.tracking) * 1000 / Double(style.fontSize) : 0
        let leading = Double(style.leading) * scale

        var out = EngineOut()
        out.line("<<")
        out.depth += 1
        out.open("EngineDict")
        out.open("Editor")
        out.text("Text", units + [13])
        out.close()
        out.open("ParagraphRun")
        out.line("/DefaultRunData << /ParagraphSheet << /DefaultStyleSheet 0 /Properties << >> >> /Adjustments << /Axis [ 1.0 0.0 1.0 ] /XY [ 0.0 0.0 ] >> >>")
        out.list("RunArray")
        for _ in paragraphLengths {
            out.line("<<")
            out.depth += 1
            out.open("ParagraphSheet")
            out.line("/DefaultStyleSheet 0")
            out.open("Properties")
            out.paragraphProperties(justification: justification)
            out.close()
            out.close()
            out.line("/Adjustments << /Axis [ 1.0 0.0 1.0 ] /XY [ 0.0 0.0 ] >>")
            out.depth -= 1
            out.line(">>")
        }
        out.closeList()
        out.line("/RunLengthArray [ \(paragraphLengths.map(String.init).joined(separator: " ")) ]")
        out.line("/IsJoinable 1")
        out.close()
        out.open("StyleRun")
        out.line("/DefaultRunData << /StyleSheet << /StyleSheetData << >> >> >>")
        out.list("RunArray")
        for segment in segments {
            out.line("<<")
            out.depth += 1
            out.open("StyleSheet")
            out.open("StyleSheetData")
            out.styleProperties(font: segment.font, size: size, leading: leading, tracking: tracking, color: segment.color)
            out.close()
            out.close()
            out.depth -= 1
            out.line(">>")
        }
        out.closeList()
        out.line("/RunLengthArray [ \(segments.map { String($0.length) }.joined(separator: " ")) ]")
        out.line("/IsJoinable 2")
        out.close()
        out.line("/GridInfo << /GridIsOn false /ShowGrid false /GridSize 18.0 /GridLeading 22.0 /GridColor << /Type 1 /Values [ 0.0 0.0 0.0 1.0 ] >> /GridLeadingFillColor << /Type 1 /Values [ 0.0 0.0 0.0 1.0 ] >> /AlignLineHeightToGridFlags false >>")
        out.line("/AntiAlias 4")
        out.line("/UseFractionalGlyphWidths true")
        out.close()
        out.resources("ResourceDict", fonts: fonts)
        out.resources("DocumentResources", fonts: fonts)
        out.depth -= 1
        out.line(">>")
        return Data(out.bytes)
    }

    // MARK: Descriptor items

    private static func textItem(_ text: String) -> Data {
        var item = PSDByteWriter()
        item.string("TEXT")
        item.unicode(text)
        return item.data
    }

    private static func enumItem(type: String, value: String) -> Data {
        var item = PSDByteWriter()
        item.string("enum")
        item.id(type)
        item.id(value)
        return item.data
    }

    private static func longItem(_ value: Int32) -> Data {
        var item = PSDByteWriter()
        item.string("long")
        item.i32(value)
        return item.data
    }

    private static func doubleItem(_ value: Double) -> Data {
        var item = PSDByteWriter()
        item.string("doub")
        item.f64(value)
        return item.data
    }

    private static func rawItem(_ payload: Data) -> Data {
        var item = PSDByteWriter()
        item.string("tdta")
        item.u32(UInt32(payload.count))
        item.bytes(payload)
        return item.data
    }

    private static func rectItem(_ box: (Double, Double, Double, Double)) -> Data {
        var item = PSDByteWriter()
        item.string("Objc")
        item.u32(0)
        item.id("Rctn")
        item.u32(4)
        for (key, value) in [("Left", box.0), ("Top ", box.1), ("Rght", box.2), ("Btom", box.3)] {
            item.id(key)
            item.string("UntF")
            item.string("#Pnt")
            item.f64(value)
        }
        return item.data
    }
}

extension PSDByteWriter {
    nonisolated mutating func f64(_ value: Double) {
        u64(value.bitPattern)
    }
    /// A length in UTF-16 units, then the units.
    nonisolated mutating func unicode(_ value: String) {
        let units = Array(value.utf16)
        u32(UInt32(units.count))
        for unit in units { u16(unit) }
    }
    /// A descriptor key or class: its length and bytes, or 0 and four bytes when it is exactly four long.
    nonisolated mutating func id(_ value: String) {
        let bytes = Array(value.utf8)
        u32(bytes.count == 4 ? 0 : UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }
    nonisolated mutating func descriptor(classID: String, items: [(String, Data)]) {
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

/// The engine dictionary as text, with tab indentation as Photoshop writes it.
private nonisolated struct EngineOut {
    var bytes: [UInt8] = []
    var depth = 0

    private mutating func indent() { bytes.append(contentsOf: [UInt8](repeating: 9, count: depth)) }

    mutating func line(_ text: String) {
        indent()
        bytes.append(contentsOf: Array(text.utf8))
        bytes.append(10)
    }
    mutating func open(_ key: String) {
        line("/\(key)")
        line("<<")
        depth += 1
    }
    mutating func close() {
        depth -= 1
        line(">>")
    }
    mutating func list(_ key: String) {
        line("/\(key)")
        line("[")
        depth += 1
    }
    mutating func closeList() {
        depth -= 1
        line("]")
    }

    /// A string as UTF-16 with a byte-order mark, parenthesized, its parentheses and backslashes escaped.
    mutating func text(_ key: String, _ units: [UInt16]) {
        indent()
        bytes.append(contentsOf: Array("/\(key) (".utf8))
        var raw: [UInt8] = [0xFE, 0xFF]
        for unit in units {
            raw.append(UInt8(truncatingIfNeeded: unit >> 8))
            raw.append(UInt8(truncatingIfNeeded: unit))
        }
        for byte in raw {
            if byte == 0x28 || byte == 0x29 || byte == 0x5C { bytes.append(0x5C) }
            bytes.append(byte)
        }
        bytes.append(contentsOf: Array(")".utf8))
        bytes.append(10)
    }

    func number(_ value: Double) -> String {
        guard value.isFinite else { return "0.0" }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.append("0") }
        return text
    }

    mutating func paragraphProperties(justification: Int) {
        line("/Justification \(justification)")
        line("/FirstLineIndent 0.0")
        line("/StartIndent 0.0")
        line("/EndIndent 0.0")
        line("/SpaceBefore 0.0")
        line("/SpaceAfter 0.0")
        line("/AutoHyphenate true")
        line("/HyphenatedWordSize 6")
        line("/PreHyphen 2")
        line("/PostHyphen 2")
        line("/ConsecutiveHyphens 8")
        line("/Zone 36.0")
        line("/WordSpacing [ 0.8 1.0 1.33 ]")
        line("/LetterSpacing [ 0.0 0.0 0.0 ]")
        line("/GlyphSpacing [ 1.0 1.0 1.0 ]")
        line("/AutoLeading 1.2")
        line("/LeadingType 0")
        line("/Hanging false")
        line("/Burasagari false")
        line("/KinsokuOrder 0")
        line("/EveryLineComposer false")
    }

    mutating func styleProperties(font: Int, size: Double, leading: Double, tracking: Double, color: (Double, Double, Double)) {
        line("/Font \(font)")
        line("/FontSize \(number(size))")
        line("/FauxBold false")
        line("/FauxItalic false")
        line("/AutoLeading \(leading > 0 ? "false" : "true")")
        line("/Leading \(number(leading))")
        line("/HorizontalScale 1.0")
        line("/VerticalScale 1.0")
        line("/Tracking \(number(tracking))")
        line("/AutoKerning true")
        line("/Kerning 0")
        line("/BaselineShift 0.0")
        line("/FontCaps 0")
        line("/FontBaseline 0")
        line("/Underline false")
        line("/Strikethrough false")
        line("/Ligatures true")
        line("/DLigatures false")
        line("/BaselineDirection 2")
        line("/Tsume 0.0")
        line("/StyleRunAlignment 2")
        line("/Language 0")
        line("/NoBreak false")
        line("/FillColor << /Type 1 /Values [ 1.0 \(number(color.0)) \(number(color.1)) \(number(color.2)) ] >>")
        line("/StrokeColor << /Type 1 /Values [ 1.0 0.0 0.0 0.0 ] >>")
        line("/FillFlag true")
        line("/StrokeFlag false")
        line("/FillFirst true")
        line("/YUnderline 1")
        line("/OutlineWidth 1.0")
        line("/CharacterDirection 0")
        line("/HindiNumbers false")
        line("/Kashida 1")
        line("/DiacriticPos 2")
    }

    mutating func resources(_ key: String, fonts: [String]) {
        open(key)
        line("/KinsokuSet [ ]")
        line("/MojiKumiSet [ ]")
        line("/TheNormalStyleSheet 0")
        line("/TheNormalParagraphSheet 0")
        list("ParagraphSheetSet")
        line("<<")
        depth += 1
        line("/Name (Normal RGB)")
        line("/DefaultStyleSheet 0")
        open("Properties")
        paragraphProperties(justification: 0)
        close()
        depth -= 1
        line(">>")
        closeList()
        list("StyleSheetSet")
        line("<<")
        depth += 1
        line("/Name (Normal RGB)")
        open("StyleSheetData")
        styleProperties(font: 0, size: 12, leading: 0, tracking: 0, color: (0, 0, 0))
        close()
        depth -= 1
        line(">>")
        closeList()
        list("FontSet")
        for name in fonts {
            line("<<")
            depth += 1
            text("Name", Array(name.utf16))
            line("/Script 0")
            line("/FontType 1")
            line("/Synthetic 0")
            depth -= 1
            line(">>")
        }
        closeList()
        line("/SuperscriptSize 0.583")
        line("/SuperscriptPosition 0.333")
        line("/SubscriptSize 0.583")
        line("/SubscriptPosition 0.333")
        line("/SmallCapSize 0.7")
        close()
    }
}
