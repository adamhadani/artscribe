import SwiftUI

/// The collapsible side panel — spec §2's *"time-aligned lanes + collapsible
/// inspector"*, and §6.2's `view.toggleInspector`.
///
/// The container, not the content. It owns three things and no more: which page
/// is showing, the header that switches between them, and the standing notice
/// about where this track's session is being written. The Practice hub lands
/// here as a second page next, which is why the page switch exists before there
/// is anything to switch to.
///
/// **Why the app's own chrome rather than the system's sidebar material.**
/// Artscribe paints every surface it owns from `Palette` — the waveform lanes,
/// the status bar, the transport — and a translucent sidebar beside a flat
/// panel reads as a different application bolted on. The panel is drawn in the
/// same two themes as everything else, and its contrast was checked in both.
struct InspectorView: View {
    let context: MenuContext
    @Environment(\.palette) private var palette

    private var inspector: InspectorController { context.inspector }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(palette.rule.color()).frame(height: 1)

            switch inspector.page {
            case .shortcuts:
                ShortcutReferenceView(context: context)
            }

            fallbackNotice
        }
        // `minWidth` as well as `.inspectorColumnWidth(min:)` on the caller's
        // side: a column narrower than this puts "Move Loop Out Right (Far)
        // 2 s" and its key cap on top of each other, and the panel's whole job
        // is to be read at a glance. Belt and braces, measured — the column came
        // back narrower than the declared minimum in a headless session.
        .frame(
            minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
        )
        .background(palette.panel.color())
    }

    /// The page switch, or — while there is only one page — its name.
    ///
    /// A one-tab picker is a lie about what is available, so the header falls
    /// back to a plain title until Task 21 gives it something to switch to.
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if InspectorPage.allCases.count > 1 {
                Picker("Page", selection: pageSelection) {
                    ForEach(InspectorPage.allCases) { page in
                        Label(page.title, systemImage: page.symbol).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Eyebrow(inspector.page.title.uppercased())
            }

            Spacer(minLength: 8)

            // The divider can be dragged shut and ⌥⌘I closes it, but neither is
            // visible, and a panel with no way out on screen is a panel people
            // leave open by accident.
            Button {
                inspector.isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.dimmed.color())
            }
            .buttonStyle(.plain)
            .help("Hide the inspector (⌥⌘I)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var pageSelection: Binding<InspectorPage> {
        Binding(get: { inspector.page }, set: { inspector.page = $0 })
    }

    /// Spec §7 and §8: *"fall back to Application Support … and surface the
    /// fallback in the inspector"*.
    ///
    /// Task 19 parked this in the title bar because no inspector existed yet.
    /// It is a standing indicator rather than a dismissible one: the banner
    /// that announces the fallback can be dismissed, after which the only thing
    /// telling you your loop points are not beside your music would be gone.
    /// It sits in the container rather than on a page, so switching pages never
    /// takes it away.
    @ViewBuilder
    private var fallbackNotice: some View {
        if context.model.isSessionStoredAwayFromTheTrack {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(palette.rule.color()).frame(height: 1)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.emphasis.color())
                    VStack(alignment: .leading, spacing: 3) {
                        Eyebrow("SESSION IN APP SUPPORT")
                        Text(
                            "This track's folder could not be written to, so its session "
                                + "is stored in Application Support instead of beside the track."
                        )
                        .font(Typography.readoutSmall)
                        .foregroundStyle(palette.dimmed.color())
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }
}
