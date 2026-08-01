import SwiftUI

#if !os(macOS)
import UIKit
#endif

/// One page of the welcome sheet.
///
/// A value rather than a view so the set can be tested — that there are four,
/// that none is empty, that the keys named exist in the catalog — without
/// rendering anything.
struct WelcomePage: Identifiable, Equatable {
    let id: Int
    let symbol: String
    let title: String
    let body: String
    /// Shown as `<kbd>`-style chips. Empty on pages where naming a key would be
    /// noise rather than help.
    var keys: [String] = []
}

extension WelcomePage {
    /// Whether to draw the key chips at all.
    ///
    /// False on iPhone. Not because keys are unavailable — iOS pairs with
    /// Bluetooth keyboards perfectly well — but because almost nobody has one
    /// attached to a phone, and a welcome that names keys the reader cannot
    /// press is worse than one that stays quiet about them.
    ///
    /// A `static var` rather than an `#if`, so the decision is one place and
    /// reads as a judgement about the device rather than about the SDK.
    ///
    /// `@MainActor` because `UIDevice.current` is: under strict concurrency it
    /// cannot be read from a nonisolated context, and this is only ever read
    /// from a view body, which already is. `make ios-check` did **not** catch
    /// that — it builds `Playback` alone and never compiles this module — so it
    /// took CI's `ios-build` job to find. Worth remembering when a change lands
    /// in `ArtscribeUI`: build the iPad scheme, not just `ios-check`.
    @MainActor
    static var showsKeys: Bool {
        #if os(macOS)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom != .phone
        #endif
    }

    /// Four pages, and deliberately not more.
    ///
    /// The HIG asks for a *"brief, enjoyable experience that doesn't require
    /// people to memorise a lot of information"*, and warns that people retain
    /// more by doing than by reading. So each page names one idea and the key
    /// that performs it, and the last one hands over to the sample track rather
    /// than continuing to explain.
    static let all: [WelcomePage] = [
        WelcomePage(
            id: 0,
            symbol: "waveform",
            title: "Welcome to Artscripture",
            body: """
                A transcription tool for the hands you already have on an \
                instrument. Load a track, select the passage you are working on, \
                and it stays where you put it.
                """),
        WelcomePage(
            id: 1,
            symbol: "repeat",
            title: "Loop a phrase, inaudibly",
            body: """
                Set the loop around a bar and it repeats without a click at the \
                seam — the stretcher is never reset at the boundary, which is \
                the difference between practising and being interrupted.
                """,
            keys: ["A", "S", "D"]),
        WelcomePage(
            id: 2,
            symbol: "tortoise",
            title: "Slow it down, stay in tune",
            body: """
                Half speed with no pitch drift you can hear. Pitch is a separate \
                control, so you can drop a passage an octave without changing \
                its tempo, or the other way round.
                """,
            keys: ["Q", "W", "1", "2", "3", "4"]),
        WelcomePage(
            id: 3,
            symbol: "metronome",
            title: "Bring it up to tempo",
            body: """
                Practice repeats your loop while the speed climbs from slow to \
                full, advancing when the loop comes round rather than on a \
                timer. Every key is listed in the shortcut reference.
                """,
            keys: ["⌘P", "⌘/"])
    ]
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

    private var isLast: Bool { page == WelcomePage.all.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            pages
            controls
        }
        .background(palette.panel.color())
    }

    private var pages: some View {
        TabView(selection: $page) {
            ForEach(WelcomePage.all) { item in
                WelcomePageView(page: item).tag(item.id)
            }
        }
        #if !os(macOS)
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
            Text("\(page + 1) of \(WelcomePage.all.count)")
                .font(Typography.readoutSmall)
                .foregroundStyle(palette.dimmed.color())
                .monospacedDigit()
            Spacer()
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
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: page.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(palette.accent.color())
            Text(page.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.text.color())
            Text(page.body)
                .font(Typography.readout)
                .foregroundStyle(palette.dimmed.color())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // **Not on a phone.** iOS does support Bluetooth keyboards, so the
            // chips are not wrong there — but almost no iPhone user has one, and
            // teaching a first-time user by naming keys they cannot press is
            // worse than teaching them nothing. The prose carries every page on
            // its own; the keys are a bonus where they can be used.
            if !page.keys.isEmpty, WelcomePage.showsKeys {
                HStack(spacing: 6) {
                    ForEach(page.keys, id: \.self) { key in
                        Text(key)
                            .font(Typography.readoutSmall)
                            .foregroundStyle(palette.text.color())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(palette.background.color())
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(palette.rule.color(), lineWidth: 1))
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .frame(maxWidth: 460)
    }
}
