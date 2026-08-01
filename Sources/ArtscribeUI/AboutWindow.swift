import SwiftUI

#if os(macOS)
import AppKit
#endif

/// **The About panel**: what this is, which build it is, where to read the
/// privacy policy, and what is inside it.
///
/// It is a compliance surface as much as a courtesy. App Store guideline
/// 5.1.1(i) requires the privacy policy to be reachable from *within* the app
/// rather than only from store metadata, and the macOS build links Rubber Band
/// under the GPL, which carries an attribution obligation. Everything it asserts
/// comes from `AboutInfo`, which is tested; this file is layout.
///
/// A window on macOS and a sheet on iPad, like the other two auxiliary views,
/// off the same `AuxiliaryWindow`. It replaces AppKit's standard About panel
/// rather than sitting beside it — see `ViewerCommands`.
public struct AboutWindow: View {
    private let about: AboutWindowController
    private let theme: ThemeController
    /// Optional so the panel can be built without one where nothing replays —
    /// and so adding this did not become a change to every call site.
    private let welcome: WelcomeState?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    /// Collapsed on opening. The licences are an obligation to *meet*, not the
    /// first thing a reader wants; the disclosure keeps the panel the size of
    /// the mock the user approved and still puts the list one click away.
    @State private var showingLicences = false

    /// Wide enough for the tagline on one line and for the longest licence row,
    /// short enough that the panel still reads as a panel. Hoisted out of the
    /// frame modifier so `theAboutPanelIsWiderThanItIsTall` can check them
    /// against each other.
    public static let minimumWidth: Double = 360
    public static let minimumHeight: Double = 280

    public init(
        about: AboutWindowController, theme: ThemeController,
        welcome: WelcomeState? = nil
    ) {
        self.about = about
        self.theme = theme
        self.welcome = welcome
    }

    private var appearance: Appearance { colorScheme == .dark ? .dark : .light }
    private var palette: Palette { Palette.of(appearance) }

    /// **"Easy for people to find if they want to view it later."** The HIG asks
    /// for exactly this alongside "don't present it again", and About is the one
    /// surface reachable without a hardware keyboard on both platforms.
    ///
    /// It asks rather than presents: two sheets cannot be raised over each other
    /// on iPad, so this sets a flag `DocumentView` acts on once About is gone.
    @ViewBuilder
    private var welcomeAgain: some View {
        if let welcome {
            Button("Show the welcome again") {
                welcome.replayRequested = true
                about.toggle()
            }
            .buttonStyle(.plain)
            .font(Typography.readoutSmall)
            .foregroundStyle(palette.accent.color())
        }
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                identity
                Text(AboutInfo.tagline(for: EmptyStatePrompt.current))
                welcomeAgain
                    .font(Typography.bannerBody)
                    .foregroundStyle(palette.text.color())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                linkRow
                licences
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
        }
        // As in `ShortcutWindow` and `PracticeWindow`: a minimum is a floor for a
        // resizable window and a fixed size for a sheet, so the two platforms
        // want different modifiers from the same numbers. The iPad cap is what
        // stops a form sheet on a 13-inch screen stretching a centred column of
        // four short lines across the whole width.
        #if os(macOS)
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
        #else
        .frame(maxWidth: 520, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        #endif
        .background(palette.background.color())
        .environment(\.palette, palette)
        .preferredColorScheme(theme.colorScheme)
        #if os(macOS)
        .background(WindowReader(onWindow: configure))
        #endif
    }

    // MARK: - Who this is

    private var identity: some View {
        VStack(spacing: 8) {
            HStack(spacing: 11) {
                AboutMark()
                Text("Artscripture")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(palette.text.color())
            }
            // Never absent, never "Version  ()". `swift run ArtscribeApp` has no
            // `Info.plist`, which is the configuration this project is developed
            // in — see `AboutInfo.line(short:build:)`.
            Text(AboutInfo.versionLine)
                .font(Typography.readout)
                .foregroundStyle(palette.dimmed.color())
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Links

    /// Website · Support · Privacy Policy.
    ///
    /// Buttons through `openURL` rather than `Link`, so the row can be styled
    /// like the rest of this app rather than like a web page, and so a URL that
    /// fails to parse cannot become a control that silently does nothing.
    private var linkRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(AboutInfo.links.enumerated()), id: \.element.id) { index, link in
                if index > 0 {
                    Text("·").foregroundStyle(palette.rule.color())
                }
                AboutLinkButton(link: link) { url in openURL(url) }
            }
        }
        .font(Typography.readout)
    }

    // MARK: - Licences

    /// The GPL and MIT attributions, behind a disclosure.
    ///
    /// The list is `AboutInfo.licences`, which asks the *platform* rather than a
    /// `#if` — so the iPadOS build's claim to contain no GPL code is something a
    /// test on a Mac can check. See `AboutInfo.licences(on:)`.
    private var licences: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(palette.rule.color()).frame(height: 1)

            Button {
                showingLicences.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showingLicences ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Open-source licences")
                    Spacer(minLength: 0)
                }
                .font(Typography.readout)
                .foregroundStyle(palette.accent.color())
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .pointerStyle(.link)
            #endif
            .accessibilityHint(showingLicences ? "Hides the list" : "Shows the list")

            if showingLicences {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AboutInfo.licences) { licence in
                        AboutLicenceRow(licence: licence)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Size and position remembered by name — `setFrameAutosaveName` rather than
    /// scene restoration, for the reason `ShortcutWindow.configure` records: an
    /// unbundled `swift run` binary has no state-restoration file to write into.
    #if os(macOS)
    private func configure(_ window: NSWindow?) {
        // Reported so the menu command can tell "open and in front" from "open
        // but behind"; without it the toggle has no window to ask.
        about.adopt(window: window)
        guard let window else { return }
        _ = window.setFrameAutosaveName(AboutWindowController.windowID)
        window.isRestorable = true
    }
    #endif
}

/// One link in the row.
///
/// A separate view for the hover state alone — `@State` in the panel itself
/// would have to be one flag per link, keyed by index.
private struct AboutLinkButton: View {
    let link: AboutLink
    let open: (URL) -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        // A link whose address will not parse is drawn dimmed and inert rather
        // than as a live control that does nothing when pressed. It should never
        // happen — `theLinksAreAbsoluteHTTPSURLs` is what makes a typo in the
        // constant a red test rather than a dead button — but "should never
        // happen" is not a reason to draw an affordance that lies.
        if let url = link.url {
            Button {
                open(url)
            } label: {
                Text(link.title)
                    .foregroundStyle(palette.accent.color())
                    .underline(hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            #if os(macOS)
            .pointerStyle(.link)
            #endif
            .accessibilityLabel("\(link.title), opens in your browser")
        } else {
            Text(link.title).foregroundStyle(palette.dimmed.color())
        }
    }
}

/// One licence: the component, its terms, and why it is in this build.
private struct AboutLicenceRow: View {
    let licence: AboutLicence
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(licence.component)
                    .font(Typography.readoutEmphasis)
                    .foregroundStyle(palette.text.color())
                Text(licence.terms)
                    .font(Typography.readoutSmall)
                    .foregroundStyle(palette.accent.color())
            }
            Text(licence.detail)
                .font(Typography.readoutSmall)
                .foregroundStyle(palette.dimmed.color())
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The wordmark's waveform, the same nine bars the website draws.
///
/// Copied from `website/_includes/mark.svg` by its geometry rather than by its
/// pixels — same widths, same gaps, same heights out of a 24-point box, and the
/// same three trailing bars in the selection colour. Two places draw this mark
/// and they should stay the same mark.
private struct AboutMark: View {
    @Environment(\.palette) private var palette

    /// Height out of 24, and whether the bar is part of the trailing tail the
    /// site tints with the selection colour.
    private static let bars: [(height: Double, tail: Bool)] = [
        (6, false), (11, false), (16, false), (20, false), (14.4, false),
        (18.4, false), (12, true), (7.6, true), (4.8, true)
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                Capsule()
                    .fill((bar.tail ? palette.selection : palette.text).color())
                    .frame(width: 2, height: bar.height)
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

#if os(macOS)

extension View {
    /// Hands the scene's `openWindow` to the controller — the whole of the
    /// plumbing behind **About Artscripture**, and the same arrangement
    /// `openShortcutWindow` describes at length.
    ///
    /// Applied to every scene that can be frontmost when the command is chosen,
    /// so it works whichever of them is key.
    public func openAboutWindow(_ about: AboutWindowController) -> some View {
        modifier(AboutWindowOpener(about: about))
    }
}

private struct AboutWindowOpener: ViewModifier {
    let about: AboutWindowController
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            about.present = { openWindow(id: AboutWindowController.windowID) }
        }
    }
}

#endif  // os(macOS) — the scene opener
