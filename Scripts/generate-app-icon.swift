#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct AppIconSlot {
    let pointSize: Int
    let scale: Int
    let filename: String

    var pixelSize: Int { pointSize * scale }
}

private enum IconGenerationError: Error {
    case contextCreationFailed(Int)
    case imageCreationFailed(Int)
    case destinationCreationFailed(URL)
    case pngFinalizationFailed(URL)
}

private let slots = [
    AppIconSlot(pointSize: 16, scale: 1, filename: "icon_16x16.png"),
    AppIconSlot(pointSize: 16, scale: 2, filename: "icon_16x16@2x.png"),
    AppIconSlot(pointSize: 32, scale: 1, filename: "icon_32x32.png"),
    AppIconSlot(pointSize: 32, scale: 2, filename: "icon_32x32@2x.png"),
    AppIconSlot(pointSize: 128, scale: 1, filename: "icon_128x128.png"),
    AppIconSlot(pointSize: 128, scale: 2, filename: "icon_128x128@2x.png"),
    AppIconSlot(pointSize: 256, scale: 1, filename: "icon_256x256.png"),
    AppIconSlot(pointSize: 256, scale: 2, filename: "icon_256x256@2x.png"),
    AppIconSlot(pointSize: 512, scale: 1, filename: "icon_512x512.png"),
    AppIconSlot(pointSize: 512, scale: 2, filename: "icon_512x512@2x.png")
]

private let fileManager = FileManager.default
private let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
private let repositoryRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let appIconDirectory = repositoryRoot
    .appendingPathComponent("Assets/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
private let previewDirectory = repositoryRoot
    .appendingPathComponent("Assets/Preview", isDirectory: true)
private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let red = CGFloat((hex >> 16) & 0xff) / 255
    let green = CGFloat((hex >> 8) & 0xff) / 255
    let blue = CGFloat(hex & 0xff) / 255
    return CGColor(
        colorSpace: colorSpace,
        components: [red, green, blue, alpha]
    )!
}

private func renderIcon(pixelSize: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: pixelSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconGenerationError.contextCreationFailed(pixelSize)
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.scaleBy(
        x: CGFloat(pixelSize) / 1_024,
        y: CGFloat(pixelSize) / 1_024
    )

    let tileRect = CGRect(x: 64, y: 64, width: 896, height: 896)
    let tilePath = CGPath(
        roundedRect: tileRect,
        cornerWidth: 216,
        cornerHeight: 216,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -18),
        blur: 34,
        color: color(0x020713, alpha: 0.46)
    )
    context.addPath(tilePath)
    context.setFillColor(color(0x0A1530))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0x1B3262), color(0x0A1530)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 190, y: 930),
        end: CGPoint(x: 850, y: 100),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    let ambientMint = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0x72E4BE, alpha: 0.13), color(0x72E4BE, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        ambientMint,
        startCenter: CGPoint(x: 650, y: 610),
        startRadius: 0,
        endCenter: CGPoint(x: 650, y: 610),
        endRadius: 570,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.13))
    context.setLineWidth(7)
    context.strokePath()
    context.restoreGState()

    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 186, y: 574))
    wave.addCurve(
        to: CGPoint(x: 392, y: 366),
        control1: CGPoint(x: 275, y: 574),
        control2: CGPoint(x: 286, y: 366)
    )
    wave.addCurve(
        to: CGPoint(x: 626, y: 662),
        control1: CGPoint(x: 506, y: 366),
        control2: CGPoint(x: 510, y: 662)
    )
    wave.addCurve(
        to: CGPoint(x: 840, y: 452),
        control1: CGPoint(x: 735, y: 662),
        control2: CGPoint(x: 754, y: 452)
    )

    context.saveGState()
    context.addPath(wave)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(118)
    context.setStrokeColor(color(0x42D1B0, alpha: 0.35))
    context.setShadow(
        offset: .zero,
        blur: 36,
        color: color(0x42D1B0, alpha: 0.42)
    )
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.addPath(wave)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(108)
    context.replacePathWithStrokedPath()
    context.clip()
    let flowGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0x9AF0C8), color(0x42D1B0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        flowGradient,
        start: CGPoint(x: 170, y: 600),
        end: CGPoint(x: 850, y: 440),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    if pixelSize >= 64 {
        context.saveGState()
        context.addPath(wave)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(13)
        context.setStrokeColor(color(0xFFFFFF, alpha: 0.19))
        context.strokePath()
        context.restoreGState()
    }

    guard let image = context.makeImage() else {
        throw IconGenerationError.imageCreationFailed(pixelSize)
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconGenerationError.destinationCreationFailed(url)
    }
    let properties = [
        kCGImagePropertyPNGDictionary: [:]
    ] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
        throw IconGenerationError.pngFinalizationFailed(url)
    }
}

private func writeContentsJSON() throws {
    let images: [[String: String]] = slots.map { slot in
        [
            "filename": slot.filename,
            "idiom": "mac",
            "scale": "\(slot.scale)x",
            "size": "\(slot.pointSize)x\(slot.pointSize)"
        ]
    }
    let catalog: [String: Any] = [
        "images": images,
        "info": [
            "author": "xcode",
            "version": 1
        ]
    ]
    var data = try JSONSerialization.data(
        withJSONObject: catalog,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    try data.write(
        to: appIconDirectory.appendingPathComponent("Contents.json"),
        options: .atomic
    )
}

try fileManager.createDirectory(
    at: appIconDirectory,
    withIntermediateDirectories: true
)
try fileManager.createDirectory(
    at: previewDirectory,
    withIntermediateDirectories: true
)

for slot in slots {
    let image = try renderIcon(pixelSize: slot.pixelSize)
    try writePNG(image, to: appIconDirectory.appendingPathComponent(slot.filename))
}

let preview = try renderIcon(pixelSize: 1_024)
try writePNG(
    preview,
    to: previewDirectory.appendingPathComponent("FlusterFlow-AppIcon-1024.png")
)
try writeContentsJSON()

print("Generated \(slots.count) macOS app-icon assets and a 1024 px preview.")
