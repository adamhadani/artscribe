import ArtscribeKit
import SwiftUI

/// The thin lane above the waveform that says where each track begins.
///
/// Its own lane rather than labels floating over the audio, and rather than
/// sharing the ruler: the ruler is also the drag-to-zoom target and already
/// carries time text, and two kinds of text in one row compete. Spec §11.4
/// reserves a markers lane for exactly this, and lanes are how this app keeps
/// anything time-aligned.
///
/// The lane draws only the labels. **The ticks continue down over the waveform**
/// as hairlines drawn by `WaveformLanesView`, because a boundary you can only
/// see in a 22pt strip is not much use when you are looking at the audio.
struct CueMarkerLaneView: View {

    @Bindable var model: ViewerModel
    let appearance: Appearance

    static let height: Double = 22

    /// Text small enough that a track name fits between two boundaries at album
    /// zoom, and large enough to read — the whole feature is a legibility
    /// trade, so this is the number it turns on.
    private static let font = Font.system(size: 10, weight: .medium)

    var body: some View {
        let palette = Palette.of(appearance)
        GeometryReader { geometry in
            let width = geometry.size.width
            let placements = layout(width: width)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(palette.panel.color())
                ForEach(placements, id: \.markerIndex) { placement in
                    tick(placement, palette: palette)
                    if let labelX = placement.labelX {
                        label(model.markers.markers[placement.markerIndex], palette: palette)
                            .offset(x: labelX, y: 4)
                    }
                }
                pinnedLabel(placements, palette: palette, width: width)
                Rectangle()
                    .fill(palette.rule.color())
                    .frame(height: 1)
                    .offset(y: Self.height - 1)
            }
            .clipped()
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Track marks")
    }

    // MARK: - Pieces

    private func tick(
        _ placement: CueLabelLayout.Placement, palette: Palette
    ) -> some View {
        Rectangle()
            .fill(palette.marker.color())
            .frame(width: 1, height: Self.height)
            .offset(x: placement.x)
    }

    private func label(_ marker: CueSheet.Marker, palette: Palette) -> some View {
        Text(marker.title)
            .font(Self.font)
            .foregroundStyle(palette.marker.color())
            .lineLimit(1)
            .fixedSize()
            // The full name at any zoom, including where the label was dropped —
            // the tick is still there to point at.
            .help("\(marker.number). \(marker.title)")
    }

    /// The track the playhead is in, pinned at the left when its own label was
    /// dropped for want of room.
    ///
    /// Borrowed from sticky headers in map and timeline UIs, and it answers the
    /// question you actually have while transcribing — *which* track is this —
    /// at the zoom where nothing else can. Suppressed when the label is already
    /// on screen, so the same name never appears twice.
    @ViewBuilder
    private func pinnedLabel(
        _ placements: [CueLabelLayout.Placement], palette: Palette, width: Double
    ) -> some View {
        let current = model.currentTrackMarker
        let onScreen = placements.first { placement in
            model.markers.markers[placement.markerIndex].number == current?.number
        }
        if let current, let onScreen, onScreen.labelX == nil {
            HStack(spacing: 0) {
                Text(current.title)
                    .font(Self.font)
                    .foregroundStyle(palette.marker.color())
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(palette.panel.color().opacity(0.92)))
                Spacer(minLength: 0)
            }
            .offset(x: 4, y: 3)
        }
    }

    // MARK: - Where things go

    /// Measures each title and asks `CueLabelLayout` which of them fit.
    ///
    /// The measuring is here and the packing is not: the layout is pure and
    /// tested, and text metrics are the one thing it cannot know. `NSAttributedString`
    /// rather than a rendered `Text`, because this runs on every viewport change
    /// and laying out real views to find out whether they fit would be circular.
    private func layout(width: Double) -> [CueLabelLayout.Placement] {
        let viewport = model.viewport
        let items = model.markers.markers.enumerated().compactMap { pair -> CueLabelLayout.Item? in
            let (index, marker) = pair
            let x = viewport.pixel(forFrame: marker.start)
            // Off-screen markers are dropped rather than laid out: at album zoom
            // on a 13-track sheet that is most of them, and a placement whose
            // tick lands at -40000 is only work.
            guard x >= -1, x <= width + 1 else { return nil }
            return CueLabelLayout.Item(
                x: x, labelWidth: Self.textWidth(marker.title), index: index)
        }
        return CueLabelLayout.place(items, width: width)
    }

    /// Cached, because a viewport change re-measures every visible title and the
    /// titles do not change until a different album is opened.
    private static let widthCache = TextWidthCache()

    static func textWidth(_ text: String) -> Double { widthCache.width(of: text, font: font) }
}

/// Remembers how wide a string is in the marker font.
///
/// Measuring text is not free and this is asked on every scroll and zoom, for
/// every visible track. Thirteen strings per album makes the cache tiny and its
/// hit rate essentially total.
@MainActor
final class TextWidthCache {
    private var widths: [String: Double] = [:]

    func width(of text: String, font: Font) -> Double {
        if let known = widths[text] { return known }
        let measured = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]
        ).size().width
        widths[text] = measured
        return measured
    }
}
