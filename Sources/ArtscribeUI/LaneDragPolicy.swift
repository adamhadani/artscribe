/// Whether pressing down in the waveform lanes should move the playhead before
/// anyone knows what the gesture is going to be.
///
/// **With a pointer, yes.** A mouse-down *is* a click until it turns out to be a
/// drag, the playhead following it is instant feedback, and it has behaved that
/// way since the first version.
///
/// **With a finger, no.** A press is the opening of a gesture whose meaning is
/// not yet decided — and the most common thing it opens is a selection, since
/// dragging one out is the first thing anybody does to a waveform. Seeking on
/// touch-down means that reaching for a passage *while the track is playing*
/// interrupts what you are listening to, at the exact moment you were trying to
/// mark it. Reported from an iPhone, and reproduced on a simulator: a
/// press-hold-drag left the playhead at the drag's start point.
///
/// A tap still seeks. It goes through `dragEnded`'s click path, which runs when
/// the finger comes up having gone nowhere — so nothing is lost, the decision is
/// only deferred until the gesture has said what it is.
///
/// Pure, and keyed on the surface rather than an `#if`, for the reason
/// `EmptyStatePrompt` records: this way both answers are checkable in one
/// `make check` instead of one per platform build.
public enum LaneDragPolicy {

    public static func seeksOnPress(on surface: EmptyStatePrompt.Surface) -> Bool {
        switch surface {
        case .desktop: return true
        case .tabletWithDrop, .phone: return false
        }
    }
}
