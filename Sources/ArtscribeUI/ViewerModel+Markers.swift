import ArtscribeKit

/// The cue-sheet track marks on the model — showing them, hiding them, and
/// saying which track the playhead is in.
///
/// The parsing is not here and neither is the file handling: `CueSheet` does the
/// first and `CueSheetLoader` the second, both testable without a model. What is
/// left is the two questions the UI actually asks.
extension ViewerModel {

    /// `T`, and View ▸ Track Marks.
    ///
    /// Guarded on there being marks to show. An item that toggles a lane which
    /// cannot appear is a control that lies about what it does — most files have
    /// no cue sheet, so this is the common case rather than an edge one, and the
    /// menu item disables itself the same way.
    public func toggleTrackMarks() {
        guard hasTrack, markers.hasMarkers else { return }
        markers.setVisible(!markers.isVisible)
        markSessionEdited()
    }

    /// Whether the marker lane should be on screen at all.
    ///
    /// Both halves matter: there is nothing to draw without marks, and the user
    /// may have put the lane away. Read by `DocumentView`, so the lane costs no
    /// vertical space when a file has no cue sheet.
    public var showsTrackMarks: Bool { markers.hasMarkers && markers.isVisible }

    /// The track the playhead is in, for the pinned label.
    public var currentTrackMarker: CueSheet.Marker? { markers.current(at: playhead) }
}
