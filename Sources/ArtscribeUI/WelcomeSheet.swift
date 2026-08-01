import SwiftUI

/// One transport button, as the welcome introduces it.
///
/// The glyph and the name are read off `TransportControl` rather than written
/// here, so a button whose symbol or wording changes changes in the tour too.
/// Only the *meaning* is the tour's own — the bar's tooltip has room for a noun
/// and this has room for a sentence.
struct ControlNote: Identifiable, Equatable {
    let control: TransportControl
    let meaning: String

    var id: String { control.rawValue }
    var symbol: String { control.glyph }
    var name: String { control.name }
    var shortcut: String { control.shortcut }
}

/// A key, and what it does. See `WelcomePage.keys`.
struct KeyNote: Identifiable, Equatable {
    let key: String
    let label: String

    var id: String { key }
}

/// One page of the welcome sheet.
///
/// A value rather than a view so the set can be tested — that there are four,
/// that none is empty, that every key and every button named really exists —
/// without rendering anything.
struct WelcomePage: Identifiable, Equatable {
    let id: Int
    let symbol: String
    let title: String
    let body: String
    /// The transport buttons this page explains, drawn as the bar draws them.
    ///
    /// **This is what the tour is mostly made of now.** It used to teach by
    /// naming keys, which is precise, unambiguous and useless to two of the
    /// three platforms — and even on a Mac it taught the chord for a thing the
    /// reader had not yet been told exists. The icon is what they will actually
    /// look for.
    var controls: [ControlNote] = []
    /// Keys for what has no button on the bar: the pitch layer, and the two
    /// panels. Suppressed where there is no keyboard.
    ///
    /// **Each carries its own label.** The first version of this was a bare row
    /// of chips reading `1 2 3 4` under a paragraph about pitch — which was
    /// wrong twice over: those are the *speed presets*, pitch is `[` and `]`,
    /// and an unlabelled row of digits below a page counter reads as a page
    /// counter. A key is only worth showing next to what it does.
    var keys: [KeyNote] = []
}

extension WelcomePage {
    /// Whether to draw the key chips at all.
    ///
    /// False on iPhone. Not because keys are unavailable — iOS pairs with
    /// Bluetooth keyboards perfectly well — but because almost nobody has one
    /// attached to a phone, and a welcome that names keys the reader cannot
    /// press is worse than one that stays quiet about them.
    ///
    /// Keyed on the surface rather than reading `UIDevice` here: that read now
    /// happens once, in `EmptyStatePrompt.current`, and everything downstream of
    /// it is a pure function whose behaviour on all three platforms can be
    /// asserted in a single `make check`.
    static func showsKeys(on surface: EmptyStatePrompt.Surface) -> Bool {
        surface != .phone
    }

    /// Four pages, and deliberately not more.
    ///
    /// The HIG asks for a *"brief, enjoyable experience that doesn't require
    /// people to memorise a lot of information"*, and warns that people retain
    /// more by doing than by reading. So each page names one idea and shows the
    /// buttons that perform it, and the last one says where the two panels live
    /// rather than trying to teach them.
    ///
    /// Ordered as the work is: open something, mark the passage, slow it down,
    /// then go and practise it.
    static func pages(for surface: EmptyStatePrompt.Surface) -> [WelcomePage] {
        [
            WelcomePage(
                id: 0,
                symbol: "waveform",
                title: "Welcome to Artscripture",
                body: """
                    A transcription tool for the hands you already have on an \
                    instrument. Load a track, mark the passage you are working \
                    on, and it stays where you put it.
                    """),
            loopPage(for: surface),
            speedPage(for: surface),
            panelsPage(for: surface)
        ]
    }

    /// The one page that has to land. Selecting is the first thing anyone does
    /// to a waveform, and until the Selection → Loop button existed it
    /// dead-ended — so the tour spends its second page on the three buttons that
    /// carry someone from a drag to a repeating bar.
    private static func loopPage(for surface: EmptyStatePrompt.Surface) -> WelcomePage {
        WelcomePage(
            id: 1,
            symbol: "repeat",
            title: "Turn a selection into a loop",
            body: EmptyStatePrompt.loopGuidance(for: surface),
            controls: [
                ControlNote(
                    control: .loopFromSelection,
                    meaning: "Makes the passage you selected into the loop."),
                ControlNote(
                    control: .loop,
                    meaning: "Repeats it, with no click at the seam."),
                ControlNote(
                    control: .preroll,
                    meaning: "Starts a moment early, so you can come in on time.")
            ])
    }

    private static func speedPage(for surface: EmptyStatePrompt.Surface) -> WelcomePage {
        WelcomePage(
            id: 2,
            symbol: "tortoise",
            title: "Slow it down, stay in tune",
            body: """
                Half speed with no pitch drift you can hear. Pitch is a separate \
                control, so a passage can drop an octave without changing tempo, \
                or the other way round.
                """,
            controls: [
                ControlNote(control: .slower, meaning: "Slower, in steps."),
                ControlNote(control: .faster, meaning: "Faster, back up to full speed.")
            ],
            // Pitch has no button on the bar, so it is named the only way it
            // can be. On a phone that leaves the sentence above carrying it,
            // which is the right trade: a chip teaches nothing to someone with
            // nothing to press.
            keys: showsKeys(on: surface)
                ? [
                    KeyNote(key: "[", label: "Pitch down"),
                    KeyNote(key: "]", label: "Pitch up")
                ]
                : [])
    }

    /// Where the rest of the app is.
    ///
    /// Practice and the shortcut reference are the two features most likely to
    /// go unfound — on a Mac they are behind menu items, and on a touch device
    /// behind the ⋯ menu, which nothing else in the tour points at.
    private static func panelsPage(for surface: EmptyStatePrompt.Surface) -> WelcomePage {
        WelcomePage(
            id: 3,
            symbol: "metronome",
            title: "Then bring it up to tempo",
            body: panelsBody(for: surface),
            keys: showsKeys(on: surface)
                ? [
                    KeyNote(key: "⌘P", label: "Practice"),
                    KeyNote(key: "⌘/", label: "Shortcuts")
                ]
                : [])
    }

    private static func panelsBody(for surface: EmptyStatePrompt.Surface) -> String {
        let practice =
            "Practice repeats your loop while the speed climbs from slow to full, "
            + "advancing when the loop comes round rather than on a timer. "
        switch surface {
        case .desktop:
            return practice
                + "It is in the Playback menu, and every key in the app is listed "
                + "in the shortcut reference beside it."
        case .tabletWithDrop, .phone:
            // Naming the glyph rather than a menu path: it is one tap away, and
            // there is no menu bar to walk without a hardware keyboard.
            return practice
                + "Open it — with Settings and the shortcut reference — from the "
                + "⋯ button in the header."
        }
    }
}

/// The first-run welcome, as a paged sheet.
///
/// Skippable at any point, never shown twice, and reachable afterwards from the
/// About panel — the three things the HIG asks of onboarding. See
/// `WelcomeState` for the guidance quoted in full.
struct WelcomeSheet: View {
    let welcome: WelcomeState
    let onClose: () -> Void
    @Environment(\.palette) private var palette
    @State private var page = 0

    /// Read once, here, and handed down. The pages are pure functions of it.
    private var surface: EmptyStatePrompt.Surface { EmptyStatePrompt.current }
    private var items: [WelcomePage] { WelcomePage.pages(for: surface) }

    private var isLast: Bool { page == items.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            pages
            controls
        }
        .background(palette.panel.color())
    }

    /// **Not a `TabView` on macOS.** `.page` is an iOS style, and a `TabView`
    /// with no style on the Mac draws AppKit's tab bar — which is what this was
    /// doing: a segmented strip of four blank tabs sitting above the welcome
    /// text, because the pages have titles but no tab labels. Nothing failed;
    /// it simply looked like a control the reader was meant to use.
    ///
    /// So the Mac shows one page and slides between them under the Next button,
    /// which is the only navigation it has anyway — there is nothing to swipe.
    @ViewBuilder
    private var pages: some View {
        #if os(macOS)
        ZStack {
            ForEach(items) { item in
                if item.id == page {
                    WelcomePageView(page: item, surface: surface)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        #else
        TabView(selection: $page) {
            ForEach(items) { item in
                WelcomePageView(page: item, surface: surface).tag(item.id)
            }
        }
        // The swipeable part. `.automatic` index display rather than
        // `.always`: the dots are drawn over the page, and on the dark panel
        // an always-on row of them under the body text reads as a control
        // the reader is meant to use rather than a position indicator.
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        #endif
    }

    private var controls: some View {
        HStack {
            // **Always present, including on the last page.** The HIG's word is
            // "optional", and a Skip that disappears once you are nearly through
            // is a smaller promise than that.
            Button("Skip") {
                welcome.markSeen()
                onClose()
            }
            .buttonStyle(.plain)
            .font(Typography.readoutSmall)
            .foregroundStyle(palette.dimmed.color())

            Spacer()

            #if os(macOS)
            // macOS has no page dots, so the position is spelled out.
            Text("\(page + 1) of \(items.count)")
                .font(Typography.readoutSmall)
                .foregroundStyle(palette.dimmed.color())
                .monospacedDigit()
            Spacer()

            // **Only on the Mac.** iOS can swipe back; here Next was the sole
            // navigation, so a reader who wanted the previous page had to
            // dismiss the sheet and replay it from About.
            if page > 0 {
                Button("Back") { withAnimation { page -= 1 } }
                    .buttonStyle(.plain)
                    .font(Typography.readoutSmall)
                    .foregroundStyle(palette.dimmed.color())
                    .padding(.trailing, 6)
            }
            #endif

            Button(isLast ? "Start" : "Next") {
                if isLast {
                    welcome.markSeen()
                    onClose()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.accent.color())
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

private struct WelcomePageView: View {
    let page: WelcomePage
    let surface: EmptyStatePrompt.Surface
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: page.symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(palette.accent.color())
            Text(page.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.text.color())
            Text(page.body)
                .font(Typography.readout)
                .foregroundStyle(palette.dimmed.color())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !page.controls.isEmpty { legend }
            if !page.keys.isEmpty { chips }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: 460)
    }

    /// The buttons, drawn as the bar draws them, one per row with what they do.
    ///
    /// Left-aligned inside a centred block: three icons and three sentences read
    /// as a key to the transport bar, and centring each row would leave the
    /// glyphs in a ragged column that no longer looks like the thing it
    /// describes.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(page.controls) { note in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: note.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.accent.color())
                        // A fixed column so the sentences line up regardless of
                        // how wide each glyph happens to be.
                        .frame(width: 20, alignment: .center)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(note.name)
                                .font(Typography.readoutSmall)
                                .foregroundStyle(palette.text.color())
                            if WelcomePage.showsKeys(on: surface) {
                                KeyChip(key: note.shortcut)
                            }
                        }
                        Text(note.meaning)
                            .font(Typography.readoutSmall)
                            .foregroundStyle(palette.dimmed.color())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: 340)
    }

    private var chips: some View {
        HStack(spacing: 14) {
            ForEach(page.keys) { note in
                HStack(spacing: 6) {
                    KeyChip(key: note.key)
                    Text(note.label)
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                }
            }
        }
        .padding(.top, 4)
    }
}

/// A key, drawn as a keycap.
private struct KeyChip: View {
    let key: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(key)
            .font(Typography.readoutSmall)
            .foregroundStyle(palette.dimmed.color())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.background.color())
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(palette.rule.color(), lineWidth: 1))
    }
}
