import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Deterministic, offline artwork generation. Run from the kit root: swift source/build.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
let raw = try Data(contentsOf: root.appendingPathComponent("source/geometry.json"))
let geometry = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
let palette = geometry["palette"] as! [String: String]
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: String) -> CGColor {
    let n = UInt32(hex.dropFirst(), radix: 16)!
    return CGColor(colorSpace: srgb, components: [CGFloat((n >> 16) & 255)/255, CGFloat((n >> 8) & 255)/255, CGFloat(n & 255)/255, 1])!
}
func write(_ data: Data, _ name: String) throws {
    let url = root.appendingPathComponent(name)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
func json(_ object: Any, _ name: String) throws {
    try write(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), name)
}
func path(_ text: String) -> CGPath {
    let t = text.split(separator: " ").map(String.init)
    var i = 0
    let p = CGMutablePath()
    func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(t[i])!) }
    while i < t.count {
        let cmd = t[i]; i += 1
        switch cmd {
        case "M": p.move(to: CGPoint(x: number(), y: number()))
        case "L": p.addLine(to: CGPoint(x: number(), y: number()))
        case "C":
            let a = CGPoint(x: number(), y: number()), b = CGPoint(x: number(), y: number()), c = CGPoint(x: number(), y: number())
            p.addCurve(to: c, control1: a, control2: b)
        case "Z": p.closeSubpath()
        default: fatalError("Unsupported vector command: \(cmd)")
        }
    }
    return p
}
let primary = geometry["primary"] as! [String: String]
let small = geometry["small"] as! [String: String]
func bird(_ c: CGContext, x: CGFloat, y: CGFloat, scale: CGFloat, fill: CGColor, optical: Bool = false, part: String? = nil) {
    c.saveGState(); c.translateBy(x: x, y: y); c.scaleBy(x: scale, y: scale)
    c.setFillColor(fill)
    for name in ["body", "wing"] where part == nil || name == part! {
        c.addPath(path((optical ? small : primary)[name]!)); c.fillPath()
    }
    c.restoreGState()
}
func raster(_ w: Int, _ h: Int, opaque: Bool = false, draw: (CGContext) -> Void) -> CGImage {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: alpha.rawValue) else { fatalError("Cannot allocate raster") }
    c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
    c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
    draw(c)
    return c.makeImage()!
}
func png(_ image: CGImage, _ name: String) throws {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGXPixelsPerMeter: 2835, kCGImagePropertyPNGYPixelsPerMeter: 2835]] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG encoding failed: \(name)") }
    try write(data as Data, name)
}
func svg(_ paths: [String: String], size: Int, fill: String, transform: String = "", background: String = "", part: String? = nil) -> Data {
    let body = ["body", "wing"].filter { part == nil || $0 == part! }.map { "<path id=\"\($0)\" d=\"\(paths[$0]!)\"/>" }.joined()
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(size)" height="\(size)" viewBox="0 0 \(size) \(size)"><title>Sotto right-facing paper songbird</title>\(background)<g fill="\(fill)" transform="\(transform)">\(body)</g></svg>
    """.data(using: .utf8)!
}
func pdf(_ name: String, w: CGFloat, h: CGFloat, draw: (CGContext) -> Void) throws {
    let data = NSMutableData(); let consumer = CGDataConsumer(data: data)!
    var box = CGRect(x: 0, y: 0, width: w, height: h)
    let c = CGContext(consumer: consumer, mediaBox: &box, nil)!
    c.beginPDFPage(nil); c.translateBy(x: 0, y: h); c.scaleBy(x: 1, y: -1)
    draw(c); c.endPDFPage(); c.closePDF(); try write(data as Data, name)
}
let terracotta = color(palette["brand"]!), graphite = color(palette["graphite"]!)
let black = color("#000000"), white = color("#FFFFFF")
let markTransform = "translate(170 190) scale(2.15)"
for (name, hex) in [("terracotta", palette["brand"]!), ("black", "#000000"), ("white", "#FFFFFF")] {
    try write(svg(primary, size: 320, fill: hex), "masters/songbird-\(name).svg")
    try pdf("masters/songbird-\(name).pdf", w: 320, h: 320) { bird($0, x: 0, y: 0, scale: 1, fill: color(hex)) }
    try png(raster(1024, 1024) { bird($0, x: 0, y: 0, scale: 3.2, fill: color(hex)) }, "brand/songbird-\(name)-1024.png")
}
try write(svg(small, size: 320, fill: "#000000"), "masters/songbird-optical-small.svg")
for part in ["body", "wing"] {
    let order = part == "body" ? "01" : "02"
    try write(svg(primary, size: 1024, fill: palette["brand"]!, transform: markTransform, part: part), "composer-layers/\(order)-\(part).svg")
}
try write(svg(primary, size: 1024, fill: palette["brand"]!, transform: markTransform), "composer-layers/01-songbird-combined.svg")
try write(Data(contentsOf: root.appendingPathComponent("source/composer.json")), "Sotto.icon/icon.json")
try write(Data(contentsOf: root.appendingPathComponent("composer-layers/01-songbird-combined.svg")), "Sotto.icon/Assets/01-songbird-combined.svg")

// Current-system sources are full bleed and unmasked; classic .icns has its own inset tile.
func appIcon(_ n: Int, appearance: String = "default", classic: Bool = false) -> CGImage {
    raster(n, n, opaque: !classic) { c in
        c.scaleBy(x: CGFloat(n)/1024, y: CGFloat(n)/1024)
        let bg = appearance == "dark" ? color(palette["dark"]!) : appearance == "tinted" ? black : graphite
        let fg = appearance == "tinted" ? white : terracotta
        c.setFillColor(bg)
        if classic {
            // Intentionally no baked shadow. 80.5% tile matches the quiet classic Dock footprint.
            c.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 184, cornerHeight: 184, transform: nil)); c.fillPath()
            c.translateBy(x: 100, y: 100); c.scaleBy(x: 824/1024, y: 824/1024)
        } else { c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
        bird(c, x: 170, y: 190, scale: 2.15, fill: fg, optical: n <= 64)
    }
}
for appearance in ["default", "dark", "tinted"] {
    try png(appIcon(1024, appearance: appearance), "app/ios/Sotto-\(appearance)-1024.png")
    let bg = appearance == "dark" ? palette["dark"]! : appearance == "tinted" ? "#000000" : palette["graphite"]!
    let fg = appearance == "tinted" ? "#FFFFFF" : palette["brand"]!
    try write(svg(primary, size: 1024, fill: fg, transform: markTransform, background: "<rect width=\"1024\" height=\"1024\" fill=\"\(bg)\"/>"), "masters/app-\(appearance)-unmasked.svg")
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try json(["info": info], "catalogs/iOS/Assets.xcassets/Contents.json")
var iosImages: [[String: Any]] = []
for appearance in ["default", "dark", "tinted"] {
    let filename = "Sotto-\(appearance)-1024.png"
    try write(Data(contentsOf: root.appendingPathComponent("app/ios/\(filename)")), "catalogs/iOS/Assets.xcassets/AppIcon.appiconset/\(filename)")
    var item: [String: Any] = ["filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"]
    if appearance != "default" { item["appearances"] = [["appearance": "luminosity", "value": appearance]] }
    iosImages.append(item)
}
try json(["images": iosImages, "info": info], "catalogs/iOS/Assets.xcassets/AppIcon.appiconset/Contents.json")
try json(["info": info], "catalogs/macOS/Assets.xcassets/Contents.json")
var macImages: [[String: Any]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let image = appIcon(points * scale, classic: true)
        try png(image, "app/macos/Sotto.iconset/\(filename)")
        try png(image, "catalogs/macOS/Assets.xcassets/AppIcon.appiconset/\(filename)")
        macImages.append(["filename": filename, "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x"])
    }
}
try json(["images": macImages, "info": info], "catalogs/macOS/Assets.xcassets/AppIcon.appiconset/Contents.json")
try png(appIcon(1024, classic: true), "app/macos/Sotto-1024.png")

// One fixed 26×18 pt canvas across states: no menu-bar reflow and no animation timer.
let states = ["Idle", "Recording", "Busy", "Error"]
func status(_ c: CGContext, state: String, fill: CGColor = CGColor(gray: 0, alpha: 1)) {
    bird(c, x: 0, y: 0.65, scale: 0.055, fill: fill, optical: true)
    c.setFillColor(fill)
    switch state {
    case "Recording": c.fillEllipse(in: CGRect(x: 20, y: 3, width: 5, height: 5))
    case "Busy":
        for x: CGFloat in [20, 22.5, 25] { c.fillEllipse(in: CGRect(x: x - 0.75, y: 8.25, width: 1.5, height: 1.5)) }
    case "Error":
        c.addPath(CGPath(roundedRect: CGRect(x: 21.5, y: 3, width: 2, height: 7), cornerWidth: 1, cornerHeight: 1, transform: nil)); c.fillPath()
        c.fillEllipse(in: CGRect(x: 21.25, y: 12, width: 2.5, height: 2.5))
    default: break
    }
}
for state in states {
    let name = "Sotto\(state)Template"
    var images: [[String: Any]] = []
    for scale in [1, 2, 3] {
        let filename = "\(name)\(scale == 1 ? "" : "@\(scale)x").png"
        let im = raster(26 * scale, 18 * scale) { c in c.scaleBy(x: CGFloat(scale), y: CGFloat(scale)); status(c, state: state) }
        try png(im, "status/png/\(filename)")
        if scale <= 2 {
            try png(im, "catalogs/macOS/Assets.xcassets/\(name).imageset/\(filename)")
            images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x"])
        }
    }
    try pdf("status/pdf/\(name).pdf", w: 26, h: 18) { status($0, state: state) }
    let badge: String
    switch state {
    case "Recording": badge = "<circle cx=\"22.5\" cy=\"5.5\" r=\"2.5\"/>"
    case "Busy": badge = [20.0,22.5,25.0].map { "<circle cx=\"\($0)\" cy=\"9\" r=\"0.75\"/>" }.joined()
    case "Error": badge = "<rect x=\"21.5\" y=\"3\" width=\"2\" height=\"7\" rx=\"1\"/><circle cx=\"22.5\" cy=\"13.25\" r=\"1.25\"/>"
    default: badge = ""
    }
    let statusPaths = ["body", "wing"].map { "<path d=\"\(small[$0]!)\"/>" }.joined()
    let statusSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"26\" height=\"18\" viewBox=\"0 0 26 18\"><g fill=\"#000000\"><g transform=\"translate(0 0.65) scale(0.055)\">\(statusPaths)</g>\(badge)</g></svg>"
    try write(statusSVG.data(using: .utf8)!, "status/svg/\(name).svg")
    try json(["images": images, "info": info, "properties": ["template-rendering-intent": "template"]], "catalogs/macOS/Assets.xcassets/\(name).imageset/Contents.json")
}
for scale in [1, 2, 3] {
    try png(raster(18 * scale, 18 * scale) { c in c.scaleBy(x: CGFloat(scale), y: CGFloat(scale)); bird(c, x: 0, y: 0.65, scale: 0.055, fill: black, optical: true) }, "status/png/SottoGlyphTemplate\(scale == 1 ? "" : "@\(scale)x").png")
}
try pdf("status/pdf/SottoGlyphTemplate.pdf", w: 18, h: 18) { bird($0, x: 0, y: 0.65, scale: 0.055, fill: black, optical: true) }

// Visual contact sheet uses the actual raster exports, never AI-rendered approximations.
func text(_ c: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 16, hex: String = "#242426", bold: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: NSColor(cgColor: color(hex))!]
    (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
}
func image(_ c: CGContext, _ im: CGImage, _ rect: CGRect, nearest: Bool = false) {
    c.saveGState(); c.interpolationQuality = nearest ? .none : .high
    c.translateBy(x: rect.minX, y: rect.maxY); c.scaleBy(x: 1, y: -1)
    c.draw(im, in: CGRect(origin: .zero, size: rect.size)); c.restoreGState()
}
func proof(_ c: CGContext) {
    c.setFillColor(color("#F5F3EF")); c.fill(CGRect(x: 0, y: 0, width: 1440, height: 1260))
    text(c, "Sotto", 64, 44, size: 42, bold: true)
    text(c, "Paper songbird · Production artwork", 65, 98, size: 20)
    image(c, appIcon(512, classic: true), CGRect(x: 44, y: 156, width: 380, height: 380))
    text(c, "macOS · classic bundle icon", 76, 548, size: 17, bold: true)
    for (i, appearance) in ["default", "dark", "tinted"].enumerated() {
        let x = CGFloat(470 + i * 310)
        c.saveGState(); c.addPath(CGPath(roundedRect: CGRect(x: x, y: 203, width: 250, height: 250), cornerWidth: 56, cornerHeight: 56, transform: nil)); c.clip()
        image(c, appIcon(512, appearance: appearance), CGRect(x: x, y: 203, width: 250, height: 250)); c.restoreGState()
        text(c, appearance.capitalized, x, 486, size: 18, bold: true)
    }
    text(c, "App sizes · native pixels (16 / 32 / 64 / 128)", 64, 613, size: 20, bold: true)
    var x: CGFloat = 64
    for n in [16, 32, 64, 128] {
        image(c, appIcon(n, classic: true), CGRect(x: x, y: 670, width: CGFloat(n), height: CGFloat(n)), nearest: true)
        text(c, "\(n)", x, 808, size: 13); x += CGFloat(n + 36)
    }
    text(c, "Menu-bar states · black/clear templates", 674, 613, size: 20, bold: true)
    for (row, dark) in [false, true].enumerated() {
        let y = CGFloat(670 + row * 76)
        c.setFillColor(color(dark ? "#242426" : "#FFFFFF")); c.fill(CGRect(x: 674, y: y, width: 686, height: 56))
        for (i, state) in states.enumerated() {
            let x = CGFloat(702 + i * 163)
            let im = raster(26, 18) { status($0, state: state, fill: dark ? white : black) }
            image(c, im, CGRect(x: x, y: y + 18, width: 26, height: 18), nearest: true)
            text(c, state, x + 36, y + 18, size: 12, hex: dark ? "#FFFFFF" : "#242426")
        }
    }
    text(c, "Small-size geometry · 8× pixel inspection", 64, 888, size: 20, bold: true)
    for (i, state) in states.enumerated() {
        let x = CGFloat(64 + i * 337)
        let im = raster(26, 18) { status($0, state: state) }
        image(c, im, CGRect(x: x, y: 946, width: 208, height: 144), nearest: true)
        text(c, state, x, 1110, size: 17, bold: true)
    }
    text(c, "Right-facing · sRGB · vector masters · optical small-size variant · no runtime animation", 64, 1200, size: 16)
}
try png(raster(1440, 1260, opaque: true, draw: proof), "previews/contact-sheet.png")
try pdf("previews/contact-sheet.pdf", w: 1440, h: 1260, draw: proof)
print("Artwork generated in \(root.path)")
