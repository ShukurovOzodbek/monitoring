#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

let canvas = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], at locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func bitmap(_ pixels: Int) -> CGContext {
    CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func tile() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: -208, y: 412))
    path.addLine(to: CGPoint(x: 208, y: 412))
    for quarter in 0..<4 {
        let rotation = CGAffineTransform(rotationAngle: -.pi / 2 * CGFloat(quarter))
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x, y: y).applying(rotation)
        }
        path.addCurve(to: point(412, 208), control1: point(367, 412), control2: point(412, 367))
        path.addLine(to: point(412, -208))
    }
    path.closeSubpath()
    var placement = CGAffineTransform(translationX: 512, y: 524)
    return path.copy(using: &placement)!
}

func renderIcon() -> CGImage {
    let context = bitmap(canvas)
    let outline = tile()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -22), blur: 30, color: color(0x140B37, alpha: 0.48))
    context.setFillColor(color(0x17123E))
    context.addPath(outline)
    context.fillPath()
    context.restoreGState()

    context.addPath(outline)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0x5743BD), color(0x222051), color(0x10112E)], at: [0, 0.51, 1]),
        start: CGPoint(x: 200, y: 960), end: CGPoint(x: 715, y: 120),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    let violet = CGPoint(x: 308, y: 833)
    context.drawRadialGradient(
        gradient([color(0xA367FF, alpha: 0.52), color(0x824EFF, alpha: 0)], at: [0, 1]),
        startCenter: violet, startRadius: 0, endCenter: violet, endRadius: 457, options: []
    )
    let cyan = CGPoint(x: 846, y: 374)
    context.drawRadialGradient(
        gradient([color(0x10B9E9, alpha: 0.37), color(0x217DE8, alpha: 0)], at: [0, 1]),
        startCenter: cyan, startRadius: 0, endCenter: cyan, endRadius: 440, options: []
    )

    context.saveGState()
    for coordinate in stride(from: 224, through: 800, by: 64) {
        let position = CGFloat(coordinate)
        context.move(to: CGPoint(x: position, y: 224))
        context.addLine(to: CGPoint(x: position, y: 800))
        context.move(to: CGPoint(x: 224, y: position))
        context.addLine(to: CGPoint(x: 800, y: position))
    }
    context.setLineWidth(2.5)
    context.replacePathWithStrokedPath()
    context.clip()
    let center = CGPoint(x: 512, y: 512)
    context.drawRadialGradient(
        gradient([color(0xBEDAFF, alpha: 0.27), color(0xBEDAFF, alpha: 0)], at: [0, 1]),
        startCenter: center, startRadius: 70, endCenter: center, endRadius: 408, options: []
    )
    context.restoreGState()

    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: 227, y: 494))
    for point in [
        CGPoint(x: 345, y: 494), CGPoint(x: 414, y: 592),
        CGPoint(x: 489, y: 345), CGPoint(x: 582, y: 685),
        CGPoint(x: 654, y: 494), CGPoint(x: 797, y: 494),
    ] {
        pulse.addLine(to: point)
    }
    context.setLineJoin(.round)
    context.setLineCap(.round)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x070928, alpha: 0.8))
    context.setStrokeColor(color(0x172053))
    context.setLineWidth(83)
    context.addPath(pulse)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.setShadow(offset: .zero, blur: 30, color: color(0x42E8FF, alpha: 0.85))
    context.setStrokeColor(color(0x64E8FF, alpha: 0.78))
    context.setLineWidth(60)
    context.addPath(pulse)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.setLineWidth(56)
    context.addPath(pulse)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        gradient([color(0xF0E5FF), color(0xEFFDFF), color(0x61F6FF)], at: [0, 0.49, 1]),
        start: CGPoint(x: 220, y: 620), end: CGPoint(x: 800, y: 440),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    context.setLineWidth(8)
    context.addPath(outline)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        gradient([color(0xF6E6FF, alpha: 0.54), color(0xACBFFF, alpha: 0.13), color(0x6BD4FF, alpha: 0.28)],
                 at: [0, 0.5, 1]),
        start: CGPoint(x: 512, y: 936), end: CGPoint(x: 512, y: 112), options: []
    )
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: url, options: .atomic)
}

func writeICNS(_ images: [(type: String, url: URL)], to output: URL) throws {
    func appendLength(_ length: Int, to data: inout Data) {
        var bigEndian = UInt32(length).bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    // ICNS stores PNG representations in typed chunks with big-endian lengths.
    var chunks = Data()
    for image in images {
        let png = try Data(contentsOf: image.url)
        chunks.append(contentsOf: image.type.utf8)
        appendLength(8 + png.count, to: &chunks)
        chunks.append(png)
    }
    var container = Data("icns".utf8)
    appendLength(8 + chunks.count, to: &container)
    container.append(chunks)
    try container.write(to: output, options: .atomic)
}

func generateIcon() throws {
    let files = FileManager.default
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
    try files.createDirectory(at: resources, withIntermediateDirectories: true)

    // Keep the generated iconset only until iconutil finishes.
    let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try files.createDirectory(at: iconset, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: iconset) }

    let master = renderIcon()
    try writePNG(master, to: resources.appendingPathComponent("AppIcon-1024.png"))
    let representations = [
        (16, "icp4", "ic11"), (32, "icp5", "ic12"), (128, "ic07", "ic13"),
        (256, "ic08", "ic14"), (512, "ic09", "ic10"),
    ]
    var images: [(type: String, url: URL)] = []
    for (size, standardType, retinaType) in representations {
        for (scale, type) in [(1, standardType), (2, retinaType)] {
            let pixels = size * scale
            let image: CGImage
            if pixels == canvas {
                image = master
            } else {
                let context = bitmap(pixels)
                context.interpolationQuality = .high
                context.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                image = context.makeImage()!
            }
            let suffix = scale == 2 ? "@2x" : ""
            let url = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
            try writePNG(image, to: url)
            images.append((type, url))
        }
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    let output = resources.appendingPathComponent("AppIcon.icns")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    if iconutil.terminationReason != .exit || iconutil.terminationStatus != 0 {
        print("iconutil failed. Writing the ICNS from the generated PNG representations.")
        try writeICNS(images, to: output)
    }
    print("Created Resources/AppIcon-1024.png and Resources/AppIcon.icns")
}

do {
    try generateIcon()
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
