#!/usr/bin/env swift
//
// Render apps/macos/Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// The icon is drawn in code rather than committed as a flat image so it stays
// editable: every dimension below is a number you can change and re-run, which
// is not true of a .icns somebody exported from a design tool once. The output
// IS committed — the build must not depend on this script having been run.
//
// Everything is laid out on a 1024pt grid and scaled down per size, following
// Apple's macOS proportions: an 824pt rounded square centered in a 1024pt
// canvas, with the leftover margin carrying the shadow.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry, all on the 1024 grid

let canvas: CGFloat = 1024
let bodySize: CGFloat = 824
let bodyX = (canvas - bodySize) / 2          // 100
let bodyY: CGFloat = 94                      // 6pt above center: the shadow needs
                                             // more room below than above.
let cornerRadius: CGFloat = 184              // ~22.3% — Apple's rounded-square ratio.

// The microphone, in body-local coordinates (0...824, y down).
let markCenterX = bodySize / 2               // 412
let capsuleWidth: CGFloat = 190
let capsuleTop: CGFloat = 118
let capsuleHeight: CGFloat = 360
let armRadius: CGFloat = 170                 // Centerline of the U beneath the capsule.
let armCenterY: CGFloat = 418
let strokeWidth: CGFloat = 50
let baseWidth: CGFloat = 240
let baseHeight: CGFloat = 50
let baseTop: CGFloat = 668

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

let gradientTop = rgb(0x7A, 0x6B, 0xFF)
let gradientBottom = rgb(0x3B, 0x2B, 0xC9)

// MARK: - Drawing

func draw(into ctx: CGContext, pixels: CGFloat) {
    // Work in the 1024 design space with y pointing down, so the numbers above
    // read the way you'd measure them on a canvas. Everything after this —
    // shadow offsets and arc angles included — is in that flipped space.
    let scale = pixels / canvas
    ctx.translateBy(x: 0, y: pixels)
    ctx.scaleBy(x: scale, y: -scale)

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let body = CGRect(x: bodyX, y: bodyY, width: bodySize, height: bodySize)
    let bodyPath = CGPath(
        roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Shadow, painted by filling the shape opaquely underneath the gradient.
    // Drawing it in its own layer keeps the blur off the gradient itself.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(gradientBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space, colors: [gradientTop, gradientBottom] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY),
        options: [])
    ctx.restoreGState()

    // The microphone.
    ctx.saveGState()
    ctx.translateBy(x: bodyX, y: bodyY)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))

    // Capsule: fully rounded, so the radius is half the width.
    let capsule = CGRect(
        x: markCenterX - capsuleWidth / 2, y: capsuleTop,
        width: capsuleWidth, height: capsuleHeight)
    ctx.addPath(CGPath(
        roundedRect: capsule, cornerWidth: capsuleWidth / 2, cornerHeight: capsuleWidth / 2,
        transform: nil))
    ctx.fillPath()

    // The U-shaped arm. In this flipped space, sweeping 0 -> pi with increasing
    // angle passes through +y, which is downward — the bottom half.
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.addArc(
        center: CGPoint(x: markCenterX, y: armCenterY), radius: armRadius,
        startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.strokePath()

    // Stem, from the bottom of the arm's centerline down to the base.
    let stem = CGRect(
        x: markCenterX - strokeWidth / 2, y: armCenterY + armRadius,
        width: strokeWidth, height: baseTop - (armCenterY + armRadius))
    ctx.fill(stem)

    // Base.
    let base = CGRect(
        x: markCenterX - baseWidth / 2, y: baseTop, width: baseWidth, height: baseHeight)
    ctx.addPath(CGPath(
        roundedRect: base, cornerWidth: baseHeight / 2, cornerHeight: baseHeight / 2,
        transform: nil))
    ctx.fillPath()

    ctx.restoreGState()
}

func render(pixels: Int, to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure("could not create a \(pixels)x\(pixels) context") }

    draw(into: ctx, pixels: CGFloat(pixels))

    guard let image = ctx.makeImage() else { throw Failure("could not snapshot the context") }
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure("could not open \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure("could not write \(url.path)") }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Assemble the .iconset and hand it to iconutil

// iconutil requires exactly these names; each is rendered at its true pixel
// size rather than downsampled from one master, so the small ones stay crisp.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("apps/macos/Resources/AppIcon.icns")

do {
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    for variant in variants {
        try render(
            pixels: variant.pixels,
            to: iconset.appendingPathComponent("\(variant.name).png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw Failure("iconutil exited \(iconutil.terminationStatus)")
    }

    print("OK  \(output.path)")
} catch {
    FileHandle.standardError.write("make-icon: \(error)\n".data(using: .utf8)!)
    exit(1)
}
