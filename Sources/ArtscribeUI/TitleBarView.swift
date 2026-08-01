import SwiftUI

/// What the header's overflow menu can open.
///
/// A value rather than four closures on `TitleBarView`, so adding a fifth
/// surface is one field here and one line in the menu rather than a change to
/// the view's shape and to every call site.
struct AuxiliaryMenuActions {
    let settings: () -> Void
    let shortcuts: () -> Void
    let practice: () -> Void
    let about: () -> Void
}

/// The header: wordmark, the loaded file, and the decode progress bar.
struct TitleBarView: View {
    let model: ViewerModel
    let onOpen: () -> Void
    /// **The only route to the auxiliary surfaces on a touch-only device.**
    ///
    /// iPadOS has a menu bar, but reaching it needs a hardware keyboard — so on
    /// a phone, or an iPad without one, `⌘,` `⌘/` and `⌘P` reach nothing at all.
    /// Settings and About had been given buttons; the shortcut reference and
    /// Practice never were, and so simply did not exist on those devices.
    ///
    /// One menu rather than four buttons: the header is already tight on a
    /// phone, and this is the shape iOS uses for exactly this — a set of
    /// destinations that are not the primary action. macOS passes nil; it has
    /// the menu bar.
    var auxiliary: AuxiliaryMenuActions?
    /// Puts the track away, returning to the resting screen and its recents.
    ///
    /// A **leading** control, which is where every Apple document app puts the
    /// way back to its library — Pages, Numbers and GarageBand all do this. On
    /// macOS it is nil: the File menu and ⇧⌘W carry it, and a Mac window does
    /// not have a "back".
    var onClose: (() -> Void)?
    @Environment(\.palette) private var palette
    #if os(macOS)
    /// Computed, not stored: a stored `private` property would make the
    /// synthesised memberwise initialiser private too, and `DocumentView`
    /// constructs this. Reading `.leading` inside `body` is what registers the
    /// observation, so this still follows a full-screen transition.
    private var trafficLights: TrafficLightInset { .shared }
    #endif

    var body: some View {
        HStack(spacing: 14) {
            if let onClose, model.hasTrack {
                Button(action: onClose) {
                    // Chevron plus a word: the glyph alone reads as "undo" or
                    // "previous track" on something with a transport bar.
                    Label("Close", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.accent.color())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close track")
            }

            Text("ARTSCRIPTURE")
                .font(Typography.eyebrow)
                .tracking(2.2)
                .foregroundStyle(palette.accent.color(opacity: 0.85))

            Rectangle()
                .fill(palette.rule.color())
                .frame(width: 1, height: 14)

            Text(model.fileName ?? "No file open")
                .font(Typography.fileName)
                .foregroundStyle(
                    model.fileName == nil
                        ? palette.dimmed.color() : palette.text.color()
                )
                .lineLimit(1)
                .truncationMode(.middle)

            // The read-only sidecar fallback used to be indicated here, then in
            // the inspector's chrome. It is now an inline banner beside the
            // decode and device notices — see `SessionFallbackBanner`.

            Spacer(minLength: 12)

            if model.isLoading {
                HStack(spacing: 8) {
                    Text(model.loadPhase?.label ?? "Loading…")
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .tint(palette.accent.color())
                        .frame(width: 130)
                    Text("\(Int((model.progress * 100).rounded()))%")
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                        .monospacedDigit()
                }
            }

            if let auxiliary {
                Menu {
                    Button("Settings…", systemImage: "gearshape", action: auxiliary.settings)
                    Button(
                        "Keyboard Shortcuts", systemImage: "keyboard",
                        action: auxiliary.shortcuts)
                    Button("Practice", systemImage: "metronome", action: auxiliary.practice)
                    Divider()
                    Button(
                        "About Artscripture", systemImage: "info.circle", action: auxiliary.about)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.dimmed.color())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }

            Button("Open…", action: onOpen)
                .buttonStyle(.plain)
                .font(Typography.readout)
                .foregroundStyle(palette.text.color())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(palette.panel.color())
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(palette.rule.color(), lineWidth: 1))
        }
        .padding(.horizontal, 14)
        // Clear of the window's traffic lights, which macOS draws on top of this
        // header — the wordmark used to read `A ● ● ● IBE`. Measured rather than
        // assumed so that full screen, where the buttons are removed, gets no
        // gap. See `TrafficLightInset`.
        #if os(macOS)
        .padding(.leading, trafficLights.leading)
        #endif
        .padding(.vertical, 9)
        .background(palette.background.color())
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.rule.color()).frame(height: 1)
        }
    }
}

/// A decode failure, shown in place rather than as a modal. The previously
/// loaded track is still on screen behind it (spec §8).
struct ErrorBannerView: View {
    @Environment(\.palette) private var palette
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.danger.color())
                .font(.system(size: 12))
            Text(message)
                .font(Typography.bannerBody)
                .foregroundStyle(palette.text.color())
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.plain)
                .font(Typography.readoutSmall)
                .foregroundStyle(palette.dimmed.color())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.danger.color(opacity: 0.12))
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.danger.color()).frame(width: 2)
        }
    }
}

/// **Spec §8: the read-only-sidecar fallback**, standing in the banner stack.
///
/// The track's folder could not be written to, so its session went into
/// Application Support instead of next to the music. Spec §7 forbids loop
/// points being silently lost because a directory was read-only, and this is
/// the "not silently" half.
///
/// Two things it is not, both deliberate. It is not **dismissible**: the four
/// banners above it announce events, and this announces a *condition* — dismiss
/// it and nothing on screen would say where your session went. And it is not
/// the `danger` red: nothing failed, the fallback worked. `emphasis` is this
/// palette's "you should know about this" colour, and it is the same amber the
/// status bar uses for a speed that is not 100%.
///
/// Task 19 parked it in the title bar for want of anywhere better; Task 20 moved
/// it into the inspector's chrome, following §8's wording; Task 25 removed the
/// inspector and it landed here, where this window already keeps everything it
/// has to say.
struct SessionFallbackBanner: View {
    let model: ViewerModel
    @Environment(\.palette) private var palette

    var body: some View {
        if model.isSessionStoredAwayFromTheTrack {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(palette.emphasis.color())
                    .font(.system(size: 12))
                Text(ViewerModel.fallbackNotice(reason: model.sessionFallbackReason))
                    .font(Typography.bannerBody)
                    .foregroundStyle(palette.text.color())
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(palette.emphasis.color(opacity: 0.12))
            .overlay(alignment: .leading) {
                Rectangle().fill(palette.emphasis.color()).frame(width: 2)
            }
        }
    }
}
