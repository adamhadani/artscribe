import ArtscribeKit
import SwiftUI

/// What the window says before anything is loaded. An empty screen is an
/// invitation to act, so it names both ways in.
struct EmptyStateView: View {
    let model: ViewerModel
    /// Taken from `MenuContext`, **not** read off the model.
    ///
    /// `ViewerModel.recents` is `@ObservationIgnored`, so reading it registers
    /// nothing with SwiftUI: this view rendered once while it was still nil —
    /// `attach(recents:)` runs after the first layout pass — and never rendered
    /// again. The list was correct, stored and reachable, and simply never
    /// appeared. The object here is `@Observable` and owned by the app shell,
    /// so `urls` is tracked and a newly opened file shows up without anything
    /// having to invalidate the view by hand.
    let recents: RecentFiles
    /// The About panel's opener, for the button below it on iPad. Carried rather
    /// than reached through the model for the same reason `recents` is.
    let about: AboutWindowController
    @Environment(\.palette) private var palette

    /// Five, not the eight the menu holds. This is a resting screen, not a
    /// browser — a short list is read at a glance, and Open Recent is still
    /// there for the rest.
    private static let shown = 5

    private var shownRecents: [URL] {
        Array(recents.urls.prefix(Self.shown))
    }

    /// The sample to offer, or `nil` when it should not be offered — either
    /// because the user has recents, or because the resource is missing from the
    /// bundle. A missing resource is a build fault, and hiding the button is
    /// better than showing one that cannot work; `SampleTrackTests` is what
    /// notices, since the app would say nothing.
    private var offeredSample: URL? {
        guard SampleTrack.isOffered(recentCount: recents.urls.count) else { return nil }
        return SampleTrack.installedURL()
    }

    var body: some View {
        VStack(spacing: 26) {
            // The drop target, drawn as one. A dashed outline does two jobs
            // here: it says *this rectangle is where a file goes*, which the
            // words alone only assert, and it separates the centred invitation
            // from the left-aligned list below it — two different kinds of
            // thing that were previously distinguished only by alignment.
            VStack(spacing: 8) {
                Text(EmptyStatePrompt.headline(for: EmptyStatePrompt.current))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.text.color())
                Text(hint)
                    .font(Typography.readout)
                    .foregroundStyle(palette.dimmed.color())
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 30)
            .frame(maxWidth: 460)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    // Dashed and dim: an invitation, not a control. A solid
                    // border at this size reads as a panel with a job, which is
                    // the wrong weight for the emptiest screen in the app.
                    .strokeBorder(
                        palette.rule.color(),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )

            // **First run only.** With no recents there is nothing to show and
            // nothing to do, and the app cannot demonstrate itself without a
            // file — which is also how a reviewer meets it (guideline 2.1). One
            // click puts a real waveform on screen.
            //
            // It disappears the moment there is a recent file, because by then
            // the list below is the better offer and a standing "try the demo"
            // would imply the app is still one. See `SampleTrack.isOffered`.
            if let sample = offeredSample {
                Button {
                    ViewerActions.open(model, url: sample)
                } label: {
                    VStack(spacing: 3) {
                        Text("Try a sample track")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.accent.color())
                        Text(SampleTrack.title)
                            .font(Typography.readoutSmall)
                            .foregroundStyle(palette.dimmed.color())
                    }
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .pointerStyle(.link)
                #endif
            }

            // Only when there is something to list. An empty "Recent" heading on
            // a first run would be a promise the app cannot keep.
            if !shownRecents.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    // **The only way to empty the list on iPad.** macOS has
                    // File ▸ Open Recent ▸ Clear Menu; iPadOS reaches the menu
                    // bar only with a hardware keyboard, so without this the
                    // list was append-only from the user's point of view —
                    // eight slots that fill and never empty short of deleting
                    // the app, which takes their preferences with it.
                    //
                    // Here on both platforms rather than iPad-only: this is
                    // where the list is *seen*, and a control that exists on one
                    // platform is a difference to remember rather than a rule.
                    HStack(alignment: .firstTextBaseline) {
                        Eyebrow("RECENT")
                        Spacer()
                        Button("Clear") { recents.clear() }
                            .buttonStyle(.plain)
                            .font(Typography.readoutSmall)
                            .foregroundStyle(palette.dimmed.color())
                            #if os(macOS)
                        .pointerStyle(.link)
                            #endif
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
                    ForEach(shownRecents, id: \.self) { url in
                        RecentEntryRow(url: url) { ViewerActions.open(model, url: url) }
                    }
                }
                // Wide enough for a long track name, narrow enough that the
                // block still reads as one thing rather than spanning a large
                // window.
                .frame(maxWidth: 460)
            }

            // **The iPad's only route to the About panel without a hardware
            // keyboard**, and therefore the only route to the privacy policy
            // that App Store guideline 5.1.1(i) requires to be reachable from
            // inside the app. macOS has the app menu and the Help menu, and a
            // link here would be a third way to say the same thing on the one
            // platform that already says it twice.
            //
            // Deliberately small and dim: this screen's job is to get a file
            // opened, and an About link that competed with the drop target for
            // attention would be answering a question nobody arrived with.
            #if !os(macOS)
            Button("About Artscripture") { about.show() }
                .buttonStyle(.plain)
                .font(Typography.readoutSmall)
                .foregroundStyle(palette.dimmed.color())
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.panel.color())
    }

    /// See `EmptyStatePrompt` — the wording differs by platform because on a
    /// phone the drop it used to describe is not possible at all.
    private var hint: String { EmptyStatePrompt.hint(for: EmptyStatePrompt.current) }
}

/// One row of the resting screen's recent list.
///
/// A whole-row button rather than a text link: the target is the row, which is
/// what a finger expects on iPad and what a pointer expects anywhere. The
/// highlight is drawn on hover *and* on press so the affordance exists for both
/// input methods — on iOS `onHover` simply never fires, which is the right
/// nothing rather than a special case.
private struct RecentEntryRow: View {
    let url: URL
    let open: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(RecentEntryLabel.name(for: url))
                    .font(Typography.fileName)
                    // The accent, not the ordinary text colour: these are the
                    // only actionable things on the screen, and the hover
                    // highlight that would otherwise say so **never fires on
                    // iPad**. Colour is the one affordance both a pointer and a
                    // finger can see.
                    .foregroundStyle(palette.accent.color())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let folder = RecentEntryLabel.folder(for: url) {
                    Text(folder)
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(palette.rule.color(opacity: hovering ? 0.5 : 0))
            )
            // The whole row, including the gap beside a short name, not just the
            // glyphs.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        #if os(macOS)
        // The pointing hand, matching the accent colour's promise. `.link` and
        // not `.grabIdle` or a crosshair: this opens a thing, it does not
        // manipulate the timeline, and the rest of this app's cursors are
        // reserved for the waveform gestures `PointerAffordance` governs.
        .pointerStyle(.link)
        #endif
    }
}
