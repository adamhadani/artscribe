import ArtscribeKit
import Foundation
import Observation

/// The track marks read from the open file's cue sheet, and whether they are
/// being shown.
///
/// A child `@Observable`, for the reason `WaveformCache` records: the lane that
/// draws these is woken when they change and left alone when the playhead moves,
/// and a nested struct would notify on every write to the parent whether or not
/// the value changed.
@MainActor
@Observable
public final class CueMarkers {

    /// Where each track begins, in ascending order. Empty when the file has no
    /// cue sheet, which is the common case.
    public internal(set) var markers: [CueSheet.Marker] = []

    /// The album's own title, when the sheet carried one.
    public internal(set) var albumTitle: String?

    /// Why there are no markers, when there is a reason worth saying out loud.
    ///
    /// Spec §8: never degrade silently. A four-`FILE` sheet sitting next to the
    /// audio and producing nothing looks exactly like a bug unless the app says
    /// which of the two it is.
    public internal(set) var notice: String?

    /// Whether the lane is shown. Persisted in the sidecar, so an album you
    /// switched them off for stays that way.
    public internal(set) var isVisible = true

    /// Just the start frames, in order — what the current-track lookup binary
    /// searches, kept alongside rather than mapped on every access because the
    /// playhead asks 62 times a second.
    public internal(set) var starts: [FrameIndex] = []

    public init() {}

    /// Whether there is anything to show. The menu item and the lane both hang
    /// off this, so "no cue sheet" costs no vertical space at all.
    public var hasMarkers: Bool { !markers.isEmpty }

    /// The track the playhead is inside, or `nil` before the first one.
    public func current(at frame: FrameIndex) -> CueSheet.Marker? {
        CueLabelLayout.currentMarker(at: frame, starts: starts).map { markers[$0] }
    }

    func adopt(_ sheet: CueSheet) {
        markers = sheet.markers
        starts = sheet.markers.map(\.start)
        albumTitle = sheet.albumTitle
        notice = nil
    }

    func clear(notice: String? = nil) {
        markers = []
        starts = []
        albumTitle = nil
        self.notice = notice
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
    }

    /// Turns a loader outcome into what the user sees.
    ///
    /// The wording is the point. "No cue sheet" is not worth saying — most files
    /// do not have one — but "there is a cue sheet here and it describes seven
    /// separate files" is, because the alternative is a user comparing an album
    /// that shows track marks against one that does not and finding no reason.
    func adopt(_ outcome: CueSheetLoader.Outcome) {
        switch outcome {
        case .none:
            clear()
        case .loaded(let sheet, _):
            adopt(sheet)
        case .rejected(let why, let url):
            clear(notice: Self.message(for: why, from: url))
        case .unreadable(let why, let url):
            clear(notice: "“\(url.lastPathComponent)” could not be read: \(why).")
        }
    }

    static func message(for rejection: CueSheet.Rejection, from url: URL) -> String {
        let name = url.lastPathComponent
        switch rejection {
        case .multipleFiles(let count):
            return "“\(name)” indexes \(count) separate audio files, so its track times are "
                + "measured inside each one rather than across this recording. No track marks."
        case .noTracks:
            return "“\(name)” has no track with a start time in it. No track marks."
        case .notACueSheet:
            return "“\(name)” is not a cue sheet. No track marks."
        }
    }
}
