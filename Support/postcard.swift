// Картинка из сгенерированной на белом: `swift Support/postcard.swift вход.png выход.heic [ширина]`.
// Белый фон становится прозрачным — чем светлее точка, тем прозрачнее, поэтому мягкие акварельные края остаются
// мягкими, — пустые поля обрезаются, ширина — не больше 480 px (240 pt на экране Retina) или заданной; мелкое
// не растягивается. HEIC хранит прозрачность и в разы легче PNG.

import AppKit
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard [3, 4].contains(arguments.count), let source = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("swift Support/postcard.swift вход.png выход.heic [ширина]") }
let limit = arguments.count == 4 ? Int(arguments[3])! : 480

let (width, height) = (source.width, source.height)
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let flags = CGImageAlphaInfo.premultipliedLast.rawValue
let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: flags)!
context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

// Белый → прозрачный: непрозрачность — насколько самый светлый канал не дотягивает до белого. Цвет при этом
// остаётся тем же поверх белого: в премультиплицированных значениях это `канал − (1 − α)`.
var (left, right, top, bottom) = (width, 0, height, 0)
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let darkest = min(pixels[i], pixels[i + 1], pixels[i + 2])
        var alpha = 255 - Int(darkest)
        if alpha < 6 { alpha = 0 }
        for c in 0..<3 { pixels[i + c] = UInt8(max(0, Int(pixels[i + c]) - (255 - alpha))) }
        pixels[i + 3] = UInt8(alpha)
        if alpha > 12 { (left, right, top, bottom) = (min(left, x), max(right, x), min(top, y), max(bottom, y)) }
    }
}

let margin = 8
let crop = CGRect(x: max(0, left - margin), y: max(0, top - margin),
                  width: min(width, right + margin) - max(0, left - margin), height: min(height, bottom + margin) - max(0, top - margin))
let cut = context.makeImage()!.cropping(to: crop)!
let outWidth = min(limit, cut.width), outHeight = Int((Double(cut.height) * Double(outWidth) / Double(cut.width)).rounded())
let out = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: flags)!
out.interpolationQuality = .high
out.draw(cut, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
let file = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, UTType.heic.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(file, out.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
CGImageDestinationFinalize(file)
print("\(outWidth)×\(outHeight)")
