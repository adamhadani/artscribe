// Draws `App/Artscribe.icns` from code.
//
// A generator rather than a committed binary: an `.icns` with every required
// size is a few hundred kilobytes of opaque blob, and the repository's
// pre-commit hook caps added files at 100 KB precisely to keep that sort of
// thing out. This file is the icon's source, it diffs, and `make app` runs it.
//
// Run standalone with `swift App/GenerateIcon.swift`, or let
// `App/generate-icon.sh` decide whether it needs re-running.
//
// The mark: a slowed-down waveform. The left half is at full width, the right
// half is the same shape stretched, drawn in the app's own amber emphasis
// colour over the dark panel — which is the one thing Artscribe does that
// nothing else on the dock does.
import AppKit
import CoreGraphics
import Foundation

// The palette, kept in step with `Sources/ArtscribeUI/Palette.swift` by hand.
// Duplicated rather than imported because this runs as a script outside the
// package, and a build-tool dependency on ArtscribeUI to draw an icon would be
// a worse trade than two colours copied.
let background = (r: 0.086, g: 0.098, b: 0.118)
let waveform = (r: 0.298, g: 0.686, b: 0.941)
let emphasis = (r: 0.965, g: 0.694, b: 0.208)

/// The waveform envelope, as a function of position across the icon. Sampled
/// twice at different rates to make the "same passage, slowed down" idea read.
func envelope(_ t: Double) -> Double {
    let slow = sin(t * 2.9) * 0.5 + 0.5
    let fast = sin(t * 11.3) * 0.5 + 0.5
    let grain = sin(t * 37.0) * 0.5 + 0.5
    return 0.20 + 0.44 * slow * (0.55 + 0.45 * fast) + 0.16 * grain
}

func draw(size: Int) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return nil }

    let side = Double(size)
    // macOS icons sit inside the grid rather than filling it.
    let inset = side * 0.09
    let rect = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let radius = rect.width * 0.225

    context.setFillColor(
        CGColor(red: background.r, green: background.g, blue: background.b, alpha: 1))
    context.addPath(
        CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
            transform: nil))
    context.fillPath()

    context.saveGState()
    context.addPath(
        CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
            transform: nil))
    context.clip()

    // The lane the waveform lives in, and the seam where the speed changes.
    let laneHeight = rect.height * 0.62
    let centre = rect.midY
    let columns = max(24, size / 6)
    let columnWidth = rect.width / Double(columns)
    let seam = Double(columns) * 0.5

    for column in 0..<columns {
        let x = rect.minX + Double(column) * columnWidth
        // Left half plays at 1×; right half is the same envelope stretched over
        // twice the distance, which is what 50% speed looks like on screen.
        let slowed = Double(column) >= seam
        let phase =
            slowed
            ? seam + (Double(column) - seam) * 0.5
            : Double(column)
        let amplitude = envelope(phase * 12.0 / Double(columns)) * laneHeight * 0.5
        let colour = slowed ? emphasis : waveform
        context.setFillColor(CGColor(red: colour.r, green: colour.g, blue: colour.b, alpha: 1))
        context.fill(
            CGRect(
                x: x + columnWidth * 0.18, y: centre - amplitude,
                width: columnWidth * 0.64, height: amplitude * 2))
    }

    // The loop bracket around the slowed half — the other half of what the app
    // is for.
    let markWidth = max(1.0, side * 0.018)
    context.setStrokeColor(CGColor(red: emphasis.r, green: emphasis.g, blue: emphasis.b, alpha: 1))
    context.setLineWidth(markWidth)
    let bracket = CGRect(
        x: rect.minX + rect.width * 0.5, y: centre - laneHeight * 0.62,
        width: rect.width * 0.5 - markWidth, height: laneHeight * 1.24)
    context.stroke(bracket)

    context.restoreGState()
    return context.makeImage()
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App")
let iconset = root.appendingPathComponent("Artscribe.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The names `iconutil` insists on.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let image = draw(size: variant.size) else {
        FileHandle.standardError.write(Data("could not draw \(variant.name)\n".utf8))
        exit(1)
    }
    let url = iconset.appendingPathComponent("\(variant.name).png")
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("could not finalise \(url.path)\n".utf8))
        exit(1)
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns", "--output", root.appendingPathComponent("Artscribe.icns").path,
    iconset.path
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
try? FileManager.default.removeItem(at: iconset)
print("wrote \(root.appendingPathComponent("Artscribe.icns").path)")
