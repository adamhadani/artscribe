import ArtscribeKit
import SwiftUI

/// The volume control in the transport bar.
///
/// Hand-drawn rather than a SwiftUI `Slider` for one concrete reason: on macOS a
/// `Slider` takes keyboard focus when you click it, and it answers the arrow keys
/// itself. Since `↑`/`↓` are the volume shortcuts, clicking the slider would move
/// the binding out from under the window's key handler and leave `⇧↑`/`⇧↓`
/// behaving differently depending on where you last clicked. This control is not
/// focusable, so the keyboard path stays the single one it claims to be.
struct VolumeSliderView: View {
    let model: ViewerModel
    @Environment(\.palette) private var palette

    private static let trackWidth: Double = 92
    private static let trackHeight: Double = 4
    private static let knobDiameter: Double = 11

    var body: some View {
        let volume = model.volume
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(volume.isMuted ? "MUTED  (M)" : "VOLUME  (↑↓)")
            HStack(spacing: 9) {
                track(volume)
                Text(Readout.percent(volume.level))
                    .font(Typography.readout)
                    .monospacedDigit()
                    .foregroundStyle(
                        volume.isMuted ? palette.dimmed.color() : palette.text.color())
            }
        }
    }

    /// Filled portion plus knob. A click anywhere jumps there, and a drag
    /// follows, which is what `minimumDistance: 0` buys.
    private func track(_ volume: VolumeState) -> some View {
        let fill = volume.isMuted ? palette.dimmed.color() : palette.accent.color()
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(palette.background.color())
                .frame(width: Self.trackWidth, height: Self.trackHeight)
            Capsule()
                .fill(fill)
                .frame(width: Self.trackWidth * volume.level, height: Self.trackHeight)
            Circle()
                .fill(fill)
                .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                .offset(x: (Self.trackWidth - Self.knobDiameter) * volume.level)
        }
        .frame(width: Self.trackWidth, height: Self.knobDiameter)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    model.setVolumeLevel(Self.level(atX: value.location.x))
                }
        )
        .accessibilityLabel("Volume")
        .accessibilityValue(Readout.percent(volume.level))
    }

    /// The knob has width, so the usable travel is the track minus the knob;
    /// mapping against the full width would make the ends unreachable.
    static func level(atX x: Double) -> Double {
        let travel = trackWidth - knobDiameter
        guard travel > 0, x.isFinite else { return 0 }
        return max(0, min(1, (x - knobDiameter / 2) / travel))
    }
}
