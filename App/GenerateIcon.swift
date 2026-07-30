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
// The mark: nine bars of a waveform, the last three in the app's amber. Slate
// is the audio, amber is the passage you have picked out and slowed down —
// which is the one thing Artscribe does that nothing else on the dock does.
//
// **Drawn for 16 points, not for 512.** An icon is looked at in a dock, a
// Finder list and a ⌘-Tab strip, and the earlier design — a dense
// forty-bar envelope with a loop bracket around half of it — was a grey smear
// at every one of those sizes. Nine bars with real gaps survive the whole
// ladder. The loop bracket went with it: a 2pt rectangle is invisible at 32
// points, and the amber already says which part is picked out.
//
// Two defects went at the same time, both of which read as bugs rather than
// choices: the bracket's right edge sat inside the corner radius and was
// visibly clipped by it, and the bars ran to the plate's edge and were clipped
// too. Everything now lives inside a safe area well clear of the curve.
import AppKit
import CoreGraphics
import Foundation

// The palette, kept in step with `Sources/ArtscribeUI/Palette.swift` by hand.
// Duplicated rather than imported because this runs as a script outside the
// package, and a build-tool dependency on ArtscribeUI to draw an icon would be
// a worse trade than two colours copied.
//
// These are the app's real inks. The previous icon's waveform was a generic
// blue that appeared nowhere in the product.
let background = (r: 0.075, g: 0.078, b: 0.090)  // 0x131417, the app background
let waveform = (r: 0.478, g: 0.533, b: 0.604)  // 0x7A889A, the waveform slate
let emphasis = (r: 0.941, g: 0.639, b: 0.369)  // 0xF0A35E, the selection amber

/// The bar heights, as fractions of the lane.
///
/// Hand-chosen rather than sampled from a sine: nine bars is too few for a
/// formula to look like anything, and this shape reads as a phrase with a peak
/// in it — loud, quieter, loud again — at every size in the ladder.
let bars: [Double] = [0.30, 0.55, 0.80, 1.00, 0.72, 0.92, 0.60, 0.38, 0.24]

/// How many of the bars, from the right, are the picked-out passage.
let emphasised = 3

/// How the square is filled.
///
/// The two platforms want opposite things, and getting it wrong is not a matter
/// of taste: **an iOS app icon must be a full-bleed opaque square with no alpha
/// channel.** The system applies its own rounded mask, and App Store validation
/// rejects transparency outright. macOS is the reverse — icons sit *inside* the
/// grid with transparent margins and draw their own rounded corners.
///
/// One drawing, two framings, so the artwork cannot drift between platforms.
enum IconStyle {
    case macOS
    case iOS

    /// Fraction of the side left empty around the artwork.
    var inset: Double {
        switch self {
        case .macOS: return 0.09
        case .iOS: return 0
        }
    }

    /// Corner radius as a fraction of the drawn rect. iOS is squared off
    /// because the system rounds it — rounding here too would show a dark
    /// hairline where our radius and theirs disagree.
    var cornerFraction: Double {
        switch self {
        case .macOS: return 0.225
        case .iOS: return 0
        }
    }
}

func draw(size: Int, style: IconStyle = .macOS) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return nil }

    let side = Double(size)
    // macOS icons sit inside the grid rather than filling it; iOS icons fill it.
    let inset = side * style.inset
    let rect = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let radius = rect.width * style.cornerFraction

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

    // The safe area. Well inside the corner radius, so nothing is ever clipped
    // by the curve — the defect this replaced.
    let safe = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.14)
    let slot = safe.width / Double(bars.count)
    // Rounded ends, which is what keeps a bar from reading as a hard rectangle
    // once it is only a few pixels wide.
    let cornerRadius = slot * 0.22

    for (index, height) in bars.enumerated() {
        let amplitude = height * safe.height * 0.44
        let colour = index >= bars.count - emphasised ? emphasis : waveform
        context.setFillColor(CGColor(red: colour.r, green: colour.g, blue: colour.b, alpha: 1))
        let bar = CGRect(
            x: safe.minX + Double(index) * slot + slot * 0.24, y: safe.midY - amplitude,
            width: slot * 0.52, height: amplitude * 2)
        context.addPath(
            CGPath(
                roundedRect: bar, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil))
        context.fillPath()
    }

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

// The iOS icon: one 1024x1024 PNG, which modern Xcode derives every other size
// from. Written into the asset catalog the iPad target points at.
//
// `CGImageAlphaInfo.noneSkipFirst` rather than `premultipliedFirst`: the PNG
// must carry no alpha channel at all. A 1024 icon with alpha is not a cosmetic
// problem — it is an App Store rejection.
let iosIconSet = root.appendingPathComponent("iOS/Assets.xcassets/AppIcon.appiconset")
if FileManager.default.fileExists(atPath: iosIconSet.path) {
    guard let iosImage = draw(size: 1024, style: .iOS) else {
        FileHandle.standardError.write(Data("could not draw the iOS icon\n".utf8))
        exit(1)
    }
    let opaque = CGContext(
        data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    guard let opaque else {
        FileHandle.standardError.write(Data("could not make an opaque iOS context\n".utf8))
        exit(1)
    }
    opaque.draw(iosImage, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    guard let flattened = opaque.makeImage() else {
        FileHandle.standardError.write(Data("could not flatten the iOS icon\n".utf8))
        exit(1)
    }
    let iosURL = iosIconSet.appendingPathComponent("icon-1024.png")
    guard
        let destination = CGImageDestinationCreateWithURL(
            iosURL as CFURL, "public.png" as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("could not write \(iosURL.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, flattened, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("could not finalise \(iosURL.path)\n".utf8))
        exit(1)
    }
    print("wrote \(iosURL.path)")
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
