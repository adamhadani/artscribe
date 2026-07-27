import ArtscribeKit
import SwiftUI

/// The bottom readout, which doubles as the transport bar (spec §8: degraded
/// state is indicated here). Every value is monospaced and every field keeps its
/// slot, so nothing shifts sideways while you zoom or while the playhead runs.
struct StatusBarView: View {
    let model: ViewerModel

    var body: some View {
        // Fixed column widths, not intrinsic ones: the zoom readout swings from
        // "19822 f/px" to "1.28 f/px" as you zoom, and a shifting column drags
        // every field to its right along with it. The position readout is the
        // worst offender of all, changing sixty times a second.
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            transport.frame(width: 172, alignment: .leading)
            // Beside the transport, not buried in a menu: the level is something
            // you reach for constantly while transcribing.
            VolumeSliderView(model: model).frame(width: 150, alignment: .leading)
            // A speed that is not 100% is the one piece of state you can forget
            // you left on, and it changes what you are hearing, so it is the one
            // readout that shouts.
            field("SPEED", speedText, emphasised: SpeedStepping.isAltered(model.speed.ratio))
                .frame(width: 150, alignment: .leading)
            field("LOOP", loopText).frame(width: 160, alignment: .leading)
            field("SELECTION", selectionText).frame(width: 150, alignment: .leading)
            field("ZOOM", zoom).frame(width: 146, alignment: .leading)
            field("FORMAT", format).frame(width: 104, alignment: .leading)
            Spacer(minLength: 8)
            if let warning {
                field("DEGRADED", warning)
                    .foregroundStyle(Palette.danger.color())
            } else if let seconds = model.lastLoadSeconds {
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

    /// Position and play state together, because they are read together: the
    /// triangle says whether the number is moving.
    private var transport: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(model.isPlaying ? "▶ PLAYING" : "■ POSITION")
            Text(positionText)
                .font(Typography.readout)
                .monospacedDigit()
                .foregroundStyle(
                    model.isPlaying ? Palette.accent.color() : Palette.text.color())
        }
    }

    /// `emphasised` bolds and colours the *value* only; the eyebrow keeps its own
    /// dimmed style, so the field still reads as one of a row rather than
    /// becoming a second heading.
    private func field(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(label)
            Text(value)
                .font(emphasised ? Typography.readoutEmphasis : Typography.readout)
                .lineLimit(1)
        }
        .foregroundStyle(emphasised ? Palette.emphasis.color() : Palette.text.color())
    }

    /// Position over length, the way every transport reads it — the length on its
    /// own (which is what this field used to show) is the less useful half.
    private var positionText: String {
        guard let audio = model.audio else { return "—" }
        let position = TimeCode.precise(frames: model.playhead, sampleRate: audio.sampleRate)
        return "\(position) / \(TimeCode.coarse(seconds: audio.duration))"
    }

    /// Speed and engine, and the fact that the graph is resampling if it is —
    /// not a failure, but the user is entitled to know it is happening.
    private var speedText: String {
        var text = "\(SpeedStepping.percentLabel(model.speed.ratio)) · \(engineLabel)"
        if model.isResampling { text += " · SRC" }
        return text
    }

    private var engineLabel: String {
        model.speed.engine == .studio ? "studio" : "fast"
    }

    private var loopText: String {
        let range = model.loop.range
        guard model.hasTrack, !range.isEmpty else { return "none" }
        let span = TimeCode.precise(
            seconds: TimeCode.seconds(frames: range.count, sampleRate: model.sampleRate))
        let start = TimeCode.coarse(frames: range.start, sampleRate: model.sampleRate)
        return "\(model.loop.isEnabled ? "on" : "off") · \(span) @ \(start)"
    }

    private var format: String {
        guard model.hasTrack else { return "—" }
        let rate = (model.sampleRate / 1000).rounded(.toNearestOrEven)
        let layout = model.channels == 2 ? "stereo" : "\(model.channels) ch"
        return "\(Int(rate)) kHz · \(layout)"
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
        let start = TimeCode.coarse(frames: range.start, sampleRate: rate)
        let span = TimeCode.precise(
            seconds: TimeCode.seconds(frames: range.count, sampleRate: rate))
        return "\(span) @ \(start)"
    }

    /// The render-thread counters. Stays on screen once it has appeared: these
    /// are monotonic, and a stall that has happened does not un-happen.
    private var warning: String? { model.degradation.summary }
}
