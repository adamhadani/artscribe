import ArtscribeKit
import SwiftUI

/// The bottom readout. Every value is monospaced and every field keeps its slot,
/// so nothing shifts sideways while you zoom.
struct StatusBarView: View {
    let model: ViewerModel

    var body: some View {
        // Fixed column widths, not intrinsic ones: the zoom readout swings from
        // "19822 f/px" to "1.28 f/px" as you zoom, and a shifting column drags
        // every field to its right along with it.
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            field("FORMAT", format).frame(width: 130, alignment: .leading)
            field("LENGTH", length).frame(width: 82, alignment: .leading)
            field("ZOOM", zoom).frame(width: 190, alignment: .leading)
            field("SELECTION", selectionText)
            Spacer(minLength: 12)
            if let seconds = model.lastLoadSeconds {
                field("LOADED IN", String(format: "%.2f s", seconds))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel.color())
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.rule.color()).frame(height: 1)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(label)
            Text(value)
                .font(Typography.readout)
                .foregroundStyle(Palette.text.color())
        }
    }

    private var format: String {
        guard model.hasTrack else { return "—" }
        let rate = (model.sampleRate / 1000).rounded(.toNearestOrEven)
        let layout = model.channels == 2 ? "stereo" : "\(model.channels) ch"
        return "\(Int(rate)) kHz · \(layout)"
    }

    private var length: String {
        guard let audio = model.audio else { return "—" }
        return TimeCode.precise(seconds: audio.duration)
    }

    private var zoom: String {
        guard model.hasTrack else { return "—" }
        let fpp = model.framesPerPixel
        let factor = model.zoomFactor
        let fppText = fpp < 10 ? String(format: "%.2f", fpp) : String(format: "%.0f", fpp)
        return "\(fppText) f/px · \(String(format: "%.1f", factor))x"
    }

    private var selectionText: String {
        let range = model.selection.range
        guard model.hasTrack, !range.isEmpty else { return "none" }
        let rate = model.sampleRate
        let start = TimeCode.precise(frames: range.start, sampleRate: rate)
        let end = TimeCode.precise(frames: range.end, sampleRate: rate)
        let span = TimeCode.precise(
            seconds: TimeCode.seconds(frames: range.count, sampleRate: rate))
        return "\(start)–\(end)  (\(span))"
    }
}
