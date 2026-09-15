#!/usr/bin/env swift
//
// Generate macOS and iOS app icons from one square source image.
//
//   swift scripts/make-icons.swift ~/Desktop/samcast-icon.png
//
// The two platforms want genuinely different things, which is why this is a
// script and not a copied-in PNG:
//
//   macOS  a rounded square floating on a transparent canvas. macOS does NOT
//          mask app icons, so a full-bleed square sits in the Dock looking
//          wrong beside every other app. Apple's grid puts the artwork in an
//          824pt rounded square on a 1024pt canvas — about 80% — with a
//          corner radius of 185.4. Those numbers are used verbatim below.
//
//   iOS    full-bleed 1024x1024 with NO transparency. iOS masks the icon
//          itself, and an alpha channel is rejected outright at submission.
//
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: swift scripts/make-icons.swift <source.png>")
    exit(1)
}

let sourceURL = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    print("error: could not read \(sourceURL.path)")
    exit(1)
}
print("source: \(source.width)x\(source.height)")
if min(source.width, source.height) < 1024 {
    print("warning: smaller than 1024px — the largest icons will be soft")
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// Draw the source into a square canvas, cropping to a centre square first so
/// a non-square input is never stretched.
func draw(into context: CGContext, size: CGFloat, inset: CGFloat, cornerRadius: CGFloat, opaque: Bool) {
    if opaque {
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    let box = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    if cornerRadius > 0 {
        context.addPath(CGPath(roundedRect: box, cornerWidth: cornerRadius,
                               cornerHeight: cornerRadius, transform: nil))
        context.clip()
    }
    context.interpolationQuality = .high

    // Centre-crop the source to a square so the aspect ratio is preserved.
    let side = CGFloat(min(source.width, source.height))
    let cropped = source.cropping(to: CGRect(
        x: (CGFloat(source.width) - side) / 2,
        y: (CGFloat(source.height) - side) / 2,
        width: side, height: side)) ?? source
    context.draw(cropped, in: box)
}

func render(size: Int, insetRatio: CGFloat, cornerRatio: CGFloat, opaque: Bool) -> CGImage? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
    ) else { return nil }
    let inset = dimension * insetRatio
    draw(into: context, size: dimension, inset: inset,
         cornerRadius: (dimension - inset * 2) * cornerRatio, opaque: opaque)
    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// ---------------------------------------------------------------- macOS ----
// Apple's grid: 824 of 1024 is the artwork, radius 185.4 of that 824.
let macInset: CGFloat = (1024 - 824) / 2 / 1024        // 0.09765
let macCorner: CGFloat = 185.4 / 824                    // 0.22500

let macSet = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
var macEntries: [String] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    guard let image = render(size: pixels, insetRatio: macInset,
                             cornerRatio: macCorner, opaque: false) else { continue }
    write(image, to: macSet.appendingPathComponent(name))
    macEntries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(points)x\(points)"
        }
    """)
}
try? """
{
  "images" : [
\(macEntries.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: macSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("macOS: 10 icons -> App/Resources/Assets.xcassets")

// ------------------------------------------------------------------ iOS ----
// Full bleed, opaque. iOS applies its own mask and rejects an alpha channel.
let iosSet = root.appendingPathComponent("App-iOS/Resources/Assets.xcassets/AppIcon.appiconset")
if let image = render(size: 1024, insetRatio: 0, cornerRatio: 0, opaque: true) {
    write(image, to: iosSet.appendingPathComponent("icon_1024.png"))
}
try? """
{
  "images" : [
    {
      "filename" : "icon_1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: iosSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("iOS: 1024x1024 -> App-iOS/Resources/Assets.xcassets")
print("now run: xcodegen generate && ./scripts/package.sh --run")
