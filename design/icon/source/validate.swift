import AppKit
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
var checks = 0
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("ARTWORK VALIDATION FAILED: \(message)") }
    checks += 1
}
func load(_ relative: String) -> CGImage {
    let url = root.appendingPathComponent(relative)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let im = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot decode \(relative)") }
    return im
}
func pixels(_ im: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: im.width * im.height * 4)
    data.withUnsafeMutableBytes { raw in
        let c = CGContext(data: raw.baseAddress, width: im.width, height: im.height, bitsPerComponent: 8, bytesPerRow: im.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        c.draw(im, in: CGRect(x: 0, y: 0, width: im.width, height: im.height))
    }
    return data
}
var fileCount = 0
for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil)! where url.pathExtension == "png" && !url.path.contains("/validation/") {
    let name = String(url.path.dropFirst(root.path.count + 1))
    let im = load(name)
    require(im.width > 0 && im.height > 0, "empty image \(name)")
    if name.hasPrefix("previews/composer-") {
        require(im.colorSpace?.name == CGColorSpace.displayP3 || im.colorSpace?.name == CGColorSpace.sRGB, "native Composer preview must retain a supported RGB profile: \(name)")
    } else {
        require(im.colorSpace?.name == CGColorSpace.sRGB, "not sRGB: \(name)")
    }
    fileCount += 1
}
for appearance in ["default", "dark", "tinted"] {
    let im = load("app/ios/Sotto-\(appearance)-1024.png")
    require(im.width == 1024 && im.height == 1024, "iOS dimensions")
    require([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(im.alphaInfo), "iOS PNG must omit alpha channel")
    let p = pixels(im)
    require(stride(from: 3, to: p.count, by: 4).allSatisfy { p[$0] == 255 }, "iOS opacity")
    if appearance == "tinted" {
        var grayscale = true
        for i in stride(from: 0, to: p.count, by: 4) { if p[i] != p[i+1] || p[i+1] != p[i+2] { grayscale = false } }
        require(grayscale, "tinted source must be grayscale")
    }
}
let mac = load("app/macos/Sotto-1024.png")
let mp = pixels(mac)
require(mp[3] == 0 && mp[(1024 * 512 + 512) * 4 + 3] == 255, "classic macOS transparent corners, opaque center")
for scale in [1, 2, 3] {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let im = load("status/png/SottoGlyphTemplate\(suffix).png")
    require(im.width == 18 * scale && im.height == 18 * scale, "compact status geometry")
    let p = pixels(im)
    require(stride(from: 0, to: p.count, by: 4).allSatisfy { p[$0] == 0 && p[$0+1] == 0 && p[$0+2] == 0 }, "template RGB must be black")
    require(stride(from: 3, to: p.count, by: 4).contains { p[$0] == 255 }, "template must have solid foreground")
    var xs: [Int] = [], ys: [Int] = []
    for y in 0..<im.height {
        for x in 0..<im.width where p[(y * im.width + x) * 4 + 3] > 16 {
            xs.append(x); ys.append(y)
        }
    }
    require(!xs.isEmpty, "glyph is empty")
    require(xs.min()! > 0 && xs.max()! < im.width - 1 && ys.min()! > 0 && ys.max()! < im.height - 1, "glyph must have unclipped transparent margins")
    require(abs(xs.min()! - (im.width - 1 - xs.max()!)) <= 1, "glyph horizontal margins differ by more than one raster pixel")
    require(abs(ys.min()! - (im.height - 1 - ys.max()!)) <= 1, "glyph vertical margins differ by more than one raster pixel")
}
for platform in ["iOS", "macOS"] {
    let catalog = root.appendingPathComponent("catalogs/\(platform)/Assets.xcassets")
    for case let url as URL in fm.enumerator(at: catalog, includingPropertiesForKeys: nil)! where url.lastPathComponent == "Contents.json" {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for item in object["images"] as? [[String: Any]] ?? [] {
            let filename = item["filename"] as! String
            require(fm.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(filename).path), "missing catalog file \(filename)")
            if platform == "macOS" {
                let scale = Int((item["scale"] as! String).dropLast())!
                let size = item["size"] as? String ?? "18x18"
                let dimensions = size.split(separator: "x").map { Int($0)! * scale }
                let im = load(String(url.deletingLastPathComponent().appendingPathComponent(filename).path.dropFirst(root.path.count + 1)))
                require(im.width == dimensions[0] && im.height == dimensions[1], "catalog slot dimensions")
            }
        }
    }
}
let icns = try Data(contentsOf: root.appendingPathComponent("app/macos/Sotto.icns"))
require(String(data: icns.prefix(4), encoding: .ascii) == "icns", "ICNS header")
require(NSImage(data: icns) != nil, "AppKit ICNS decoding")
let summary: [String: Any] = ["checks": checks, "pngFilesDecoded": fileCount, "result": "passed", "validated": ["sRGB profiles", "PNG decoding", "iOS dimensions and no alpha", "grayscale tint", "classic macOS alpha", "template black/clear pixels", "centered compact glyph and unclipped margins", "asset catalog references and sizes", "AppKit ICNS decoding"]]
try fm.createDirectory(at: root.appendingPathComponent("validation"), withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("validation/pixel-checks.json"))
print("PASS: \(checks) checks; \(fileCount) PNG files decoded")
