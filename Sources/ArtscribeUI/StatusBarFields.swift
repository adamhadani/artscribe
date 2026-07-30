import CoreGraphics

/// What the status bar shows, and the order in which it gives things up.
///
/// Pure data and pure functions, separate from `StatusBarView`, because views
/// here are not snapshot-tested — the project's rule is to extract the logic and
/// test that. What is testable about a status bar is *which fields survive at a
/// given width and in what order*, and that is all this holds.
///
/// ## Why anything is dropped at all
///
/// Every column is a fixed width, deliberately: the zoom readout swings between
/// `19822 f/px` and `1.28 f/px`, and the position readout changes sixty times a
/// second, so intrinsic widths would drag every field to their right sideways
/// while you work. The cost of that decision is that the row has a hard minimum
/// width — 1144 pt with everything shown — and cannot compress below it.
///
/// It used to simply overflow and clip, which lost `FORMAT` and the trailing
/// field with nothing to say they were gone. Dropping fields deliberately, worst
/// first, keeps the row honest at any width.
enum StatusBarFields {

    enum Field: String, CaseIterable, Sendable {
        case position
        case volume
        case speed
        case loop
        case selection
        case zoom
        case format
    }

    /// Left-to-right order on screen. Dropping never reorders what is left.
    static let displayOrder: [Field] = [
        .position, .volume, .speed, .loop, .selection, .zoom, .format
    ]

    /// Given up in this order, first entry first.
    ///
    /// `format` goes first because a file's sample rate and channel count do not
    /// change while you work — you read it once on load, and the title bar and
    /// the load notice already carry the file's identity. `zoom` next: the
    /// waveform *is* the zoom readout, so the number is a refinement of
    /// something already on screen. `selection` and `loop` are last because they
    /// are the two pieces of state you can leave set and forget, and both change
    /// what the transport does.
    static let dropOrder: [Field] = [.format, .zoom, .selection, .loop]

    /// Never dropped, at any width.
    ///
    /// Position is what a transport is for. Volume is the control you reach for
    /// most while transcribing. Speed is the one setting you can forget you left
    /// on, and it changes what you are hearing — spec §8's "never degrade
    /// silently" applies to the readout as much as to the audio.
    static let essential: [Field] = [.position, .volume, .speed]

    /// The fields still shown after giving up the first `count` of `dropOrder`.
    static func visible(dropping count: Int) -> [Field] {
        let surrendered = Set(dropOrder.prefix(max(0, count)))
        return displayOrder.filter { !surrendered.contains($0) }
    }

    /// Every arrangement, widest first — which is the order `ViewThatFits` needs:
    /// it takes the first child that fits the proposed width.
    static var candidates: [[Field]] {
        (0...dropOrder.count).map { visible(dropping: $0) }
    }

    /// Column widths, in points. Together with the spacing and padding in
    /// `StatusBarView` these are what decide when a candidate stops fitting.
    static func width(of field: Field) -> CGFloat {
        switch field {
        case .position: return 172
        case .volume: return 150
        case .speed: return 150
        case .loop: return 160
        case .selection: return 150
        case .zoom: return 146
        case .format: return 104
        }
    }
}
