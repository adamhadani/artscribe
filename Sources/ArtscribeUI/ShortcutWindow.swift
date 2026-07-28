import AppKit
import SwiftUI

/// **The shortcut reference, as its own window**: a keyboard with the bindings
/// drawn on it, a list beside it, and one filter over both.
///
/// It was an inspector page in Task 20 and the user asked for this instead —
/// "clear and legible but also visually intuitive". A separate window rather
/// than a panel is what that costs: the reference is a thing you keep open on a
/// second display while you learn the keymap, and a panel inside the document
/// window can only be that by taking width from the waveform, which is the one
/// thing this app is for.
///
/// Three decisions worth keeping:
///
/// * **The keyboard is the mockup the user already approved**
///   (`.superpowers/brainstorm/…/keyboard.html`) — they chose this project's
///   entire keymap off it. Category tinting, dimmed unbound keys, the action
///   named under the glyph. Not a new design.
/// * **Layers follow the modifiers you hold** (see `ShortcutLayers`), and can
///   also be pinned from the picker for anyone who cannot hold two keys at
///   once. That is an accessibility requirement, not a nicety.
/// * **Everything comes from `ActionCatalog`.** No second list. The window
///   cannot show a shortcut the app does not have, and
///   `everyActionInTheCatalogIsReachableInTheWindow` is what stops the reverse.
public struct ShortcutWindow: View {
    private let context: MenuContext
    private let theme: ThemeController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What is being held **right now**. `@State` and compared before writing,
    /// so a `.flagsChanged` for a key this app does not read cannot invalidate
    /// the whole keyboard.
    @State private var held: KeyModifiers = []
    @State private var modifiers = ModifierMonitor()

    public init(context: MenuContext, theme: ThemeController) {
        self.context = context
        self.theme = theme
    }

    private var shortcuts: ShortcutWindowController { context.shortcuts }
    private var appearance: Appearance { colorScheme == .dark ? .dark : .light }
    private var palette: Palette { Palette.of(appearance) }
    private var layer: KeyModifiers {
        ShortcutLayers.effective(held: held, pinned: shortcuts.pinnedLayer)
    }

    public var body: some View {
        @Bindable var shortcuts = shortcuts
        return VStack(spacing: 0) {
            header(query: $shortcuts.query)
            Rectangle().fill(palette.rule.color()).frame(height: 1)
            HStack(spacing: 0) {
                ShortcutKeyboardView(
                    layer: layer, query: shortcuts.query, appearance: appearance
                )
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Spec §12 and the brief: Reduce Motion turns the layer
                // cross-fade off rather than shortening it. A keyboard that
                // repaints eight keys at once is exactly the kind of movement
                // the setting exists for.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: layer)

                Rectangle().fill(palette.rule.color()).frame(width: 1)

                ShortcutListView(
                    context: context, query: shortcuts.query, appearance: appearance
                )
                .frame(minWidth: 250, idealWidth: 310, maxWidth: 380)
                .background(palette.panel.color())
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(palette.background.color())
        .environment(\.palette, palette)
        .preferredColorScheme(theme.colorScheme)
        .background(WindowReader(onWindow: configure))
        .onAppear {
            modifiers.start { held in
                // Compared before writing: `@State` invalidates on every set,
                // and AppKit sends `.flagsChanged` for keys nothing here reads.
                if held != self.held { self.held = held }
            }
        }
        .onDisappear {
            modifiers.stop()
            held = []
        }
    }

    // MARK: - Chrome

    private func header(query: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Eyebrow("KEYBOARD SHORTCUTS")

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.dimmed.color())
                // One field over both surfaces: it narrows the list *and*
                // quiets every key on the keyboard that is not a match.
                TextField("Filter", text: query)
                    .textFieldStyle(.plain)
                    .font(Typography.readout)
                    .foregroundStyle(palette.text.color())
                if !query.wrappedValue.isEmpty {
                    Button {
                        query.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.dimmed.color())
                    }
                    .buttonStyle(.plain)
                    .help("Clear the filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 220)
            .background(RoundedRectangle(cornerRadius: 5).fill(palette.panel.color()))
            .overlay(
                RoundedRectangle(cornerRadius: 5).stroke(palette.rule.color(), lineWidth: 1))

            Spacer(minLength: 8)
            layerPicker
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.background.color())
    }

    /// The layer switch, and the sentence explaining that it is optional.
    ///
    /// It **shows the effective layer and writes the pinned one**, which is the
    /// whole trick: holding `⌥` moves the picker to `⌥` and letting go moves it
    /// back, so the held gesture is legible as the same control the picker is,
    /// and a click is the way to get there without holding anything.
    private var layerPicker: some View {
        HStack(spacing: 10) {
            Text(held.isEmpty ? "Hold ⇧ ⌥ ⌘ — or pick a layer" : "Holding")
                .font(Typography.readoutSmall)
                .foregroundStyle(held.isEmpty ? palette.dimmed.color() : palette.accent.color())
            Picker("Layer", selection: layerSelection) {
                ForEach(ShortcutLayers.available, id: \.rawValue) { modifiers in
                    Text(ShortcutLayers.title(modifiers)).tag(modifiers)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show a modifier layer without holding the keys")
        }
    }

    private var layerSelection: Binding<KeyModifiers> {
        Binding(get: { layer }, set: { shortcuts.pin($0) })
    }

    /// Size and position remembered, by name.
    ///
    /// `setFrameAutosaveName` rather than trusting scene restoration: an
    /// unbundled `swift run` binary has no state-restoration file to write into,
    /// so the frame would be forgotten in exactly the configuration every agent
    /// and every developer on this project actually runs.
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        _ = window.setFrameAutosaveName(ShortcutWindowController.windowID)
        window.isRestorable = true
    }
}

extension View {
    /// Hands the scene's `openWindow` to the controller.
    ///
    /// This is the whole of the plumbing behind `⌘/`. `openWindow` is an
    /// `EnvironmentValues` member and so only reachable from a `View`, while
    /// the thing that needs it — `ActionInvoker`'s table — is deliberately not
    /// a view: it is the single implementation of every action, reached
    /// identically from a menu item, a key press, and later a MIDI note.
    ///
    /// Applied to **both** scenes that can be showing when `⌘/` is pressed, so
    /// the key works whichever of them is key.
    public func openShortcutWindow(_ shortcuts: ShortcutWindowController) -> some View {
        modifier(ShortcutWindowOpener(shortcuts: shortcuts))
    }
}

private struct ShortcutWindowOpener: ViewModifier {
    let shortcuts: ShortcutWindowController
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            shortcuts.present = { openWindow(id: ShortcutWindowController.windowID) }
        }
    }
}
