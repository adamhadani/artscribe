/// **The list.** One row per action, and the only place a shortcut is written
/// down.
///
/// Split from `ActionCatalog` for file length alone; it is the same table. The
/// order within each block is the order the menu draws — `MenuPlan` says where
/// the separators go, and nothing else about the arrangement.
extension ActionCatalog {
    static let allEntries: [ActionEntry] =
        transportEntries + navigationEntries + loopEntries + loopMoveEntries + practiceEntries
        + speedEntries + pitchEntries + volumeEntries + selectionEntries + viewEntries + fileEntries
        + applicationEntries

    // MARK: - Playback ▸ transport

    static let transportEntries: [ActionEntry] = [
        // The bare `Space` toggles play/pause, and `⇧Space` is the variant of it
        // that starts from the top. Task 28 swapped the two; the user drove the
        // swapped build and asked for this back, so a `Space` pressed while
        // playing pauses again rather than restarting. Since Task 29 a resume
        // also rolls back by the configurable **preroll** (`Preroll`), which is
        // what makes a pause-and-listen-again land you slightly before the note
        // you stopped on.
        ActionEntry(
            .transportPlayPause, "Play", .transport,
            chords: [KeyChord(.space)], menu: .playback, enablement: .track),
        // No shortcut, and never had one: Space is play/pause, and a separate
        // Stop key would be a third way to say the same thing.
        ActionEntry(.transportStop, "Stop", .transport, menu: .playback, enablement: .trackPlaying),
        // ⇧Space, not Return: it keeps the whole transport under the left hand,
        // next to the Space it is a variant of. No preroll — it already has an
        // explicit target (`PlaybackStart`).
        ActionEntry(
            .transportReturnToStart, "Play from Start", .transport,
            chords: [KeyChord(.space, .shift)], menu: .playback, enablement: .track),
        // `H` sits directly right of `G`, extending the `A S D F G` loop row by
        // one — the preroll belongs to that cluster by hand position as much as
        // by meaning. A toggle rather than a second amount: `0` already turns
        // the preroll off, but zeroing it *forgets* the seconds you chose, and
        // this is a mode you flip while working, the way a DAW does.
        ActionEntry(
            .transportPrerollToggle, "Preroll", .transport,
            chords: [.key("h")], menu: .playback, enablement: .track, kind: .toggle)
    ]

    // MARK: - Playback ▸ navigation (spec §6.2's three nudge tiers)

    /// Two chords each on the normal and coarse tiers: the left-hand cluster
    /// and the arrows both reach them. The menu draws the first.
    static let navigationEntries: [ActionEntry] = [
        ActionEntry(
            .nudgeBack, "Nudge Back", .navigation,
            chords: [.key("z"), KeyChord(.leftArrow)], menu: .playback, enablement: .track),
        ActionEntry(
            .nudgeForward, "Nudge Forward", .navigation,
            chords: [.key("x"), KeyChord(.rightArrow)], menu: .playback, enablement: .track),
        ActionEntry(
            .nudgeBackFine, "Nudge Back (Fine)", .navigation,
            chords: [.key("z", .shift)], menu: .playback, enablement: .track),
        ActionEntry(
            .nudgeForwardFine, "Nudge Forward (Fine)", .navigation,
            chords: [.key("x", .shift)], menu: .playback, enablement: .track),
        ActionEntry(
            .nudgeBackCoarse, "Rewind", .navigation,
            chords: [.key("z", .option), KeyChord(.leftArrow, .option)],
            menu: .playback, enablement: .track),
        ActionEntry(
            .nudgeForwardCoarse, "Skip", .navigation,
            chords: [.key("x", .option), KeyChord(.rightArrow, .option)],
            menu: .playback, enablement: .track)
    ]

    // MARK: - Loop

    static let loopEntries: [ActionEntry] = [
        ActionEntry(
            .loopSetIn, "Set Loop In", .loop,
            chords: [.key("a")], menu: .loop, enablement: .track),
        ActionEntry(
            .loopSetOut, "Set Loop Out", .loop,
            chords: [.key("s")], menu: .loop, enablement: .track),
        ActionEntry(
            .loopToggle, "Loop", .loop,
            chords: [.key("d")], menu: .loop, enablement: .trackLoopToggle, kind: .toggle),
        ActionEntry(
            .loopRestart, "Restart Loop", .loop,
            chords: [.key("f")], menu: .loop, enablement: .trackLoop),
        ActionEntry(
            .loopFromSelection, "Selection → Loop", .loop,
            chords: [.key("g")], menu: .loop, enablement: .trackSelection),
        ActionEntry(.loopClear, "Clear Loop", .loop, menu: .loop, enablement: .trackLoop)
    ]

    /// The twelve `loop.move` items. `A S D F` is the loop row and reads left to
    /// right; ⇧ turns "set this edge at the playhead" into "nudge it from where
    /// it is"; ⌥ *adds* the bigger step rather than replacing the ⇧.
    static let loopMoveEntries: [ActionEntry] = [
        loopMove(.loopMoveInLeft, "Move Loop In Left", .key("a", .shift)),
        loopMove(.loopMoveInRight, "Move Loop In Right", .key("s", .shift)),
        loopMove(.loopMoveInLeftFar, "Move Loop In Left (Far)", .key("a", [.shift, .option])),
        loopMove(.loopMoveInRightFar, "Move Loop In Right (Far)", .key("s", [.shift, .option])),
        loopMove(.loopMoveOutLeft, "Move Loop Out Left", .key("d", .shift)),
        loopMove(.loopMoveOutRight, "Move Loop Out Right", .key("f", .shift)),
        loopMove(.loopMoveOutLeftFar, "Move Loop Out Left (Far)", .key("d", [.shift, .option])),
        loopMove(.loopMoveOutRightFar, "Move Loop Out Right (Far)", .key("f", [.shift, .option])),
        loopMove(.loopMoveLeft, "Move Loop Left", .key("c", .shift)),
        loopMove(.loopMoveRight, "Move Loop Right", .key("v", .shift)),
        loopMove(.loopMoveLeftFar, "Move Loop Left (Far)", .key("c", [.shift, .option])),
        loopMove(.loopMoveRightFar, "Move Loop Right (Far)", .key("v", [.shift, .option]))
    ]

    private static func loopMove(
        _ id: ActionID, _ title: String, _ chord: KeyChord
    ) -> ActionEntry {
        ActionEntry(id, title, .loop, chords: [chord], menu: .loop, enablement: .trackLoop)
    }

    // MARK: - Playback ▸ speed

    static let speedEntries: [ActionEntry] = [
        ActionEntry(
            .speedUp, "Faster", .speed, chords: [.key("w")], menu: .playback, enablement: .track),
        ActionEntry(
            .speedDown, "Slower", .speed, chords: [.key("q")], menu: .playback, enablement: .track),
        ActionEntry(
            .speedUpFine, "Faster (Fine)", .speed,
            chords: [.key("w", .shift)], menu: .playback, enablement: .track),
        ActionEntry(
            .speedDownFine, "Slower (Fine)", .speed,
            chords: [.key("q", .shift)], menu: .playback, enablement: .track),
        preset(.speedPreset100, "100% Speed", "1"),
        preset(.speedPreset75, "75% Speed", "2"),
        preset(.speedPreset50, "50% Speed", "3"),
        preset(.speedPreset33, "33% Speed", "4")
    ]

    // MARK: - Playback ▸ pitch
    //
    // `[` and `]` are the bracket pair immediately right of `P`, they read as
    // "down" and "up" by shape, and no layer used them. Deliberately *not* on
    // the `Q W` speed keys: pitch and speed being independent is the feature,
    // and putting them on adjacent keys of the same cluster would invite exactly
    // the confusion the separation exists to avoid. `⇧` gives the one-cent step,
    // matching every other fine variant in this catalog.
    static let pitchEntries: [ActionEntry] = [
        ActionEntry(
            .pitchUp, "Pitch Up", .speed,
            chords: [.key("]")], menu: .playback, enablement: .track,
            note: "One semitone, independent of speed"),
        ActionEntry(
            .pitchDown, "Pitch Down", .speed,
            chords: [.key("[")], menu: .playback, enablement: .track,
            note: "One semitone, independent of speed"),
        ActionEntry(
            .pitchUpFine, "Pitch Up (Fine)", .speed,
            chords: [.key("]", .shift)], menu: .playback, enablement: .track,
            note: "One cent"),
        ActionEntry(
            .pitchDownFine, "Pitch Down (Fine)", .speed,
            chords: [.key("[", .shift)], menu: .playback, enablement: .track,
            note: "One cent"),
        ActionEntry(
            .pitchReset, "Reset Pitch", .speed,
            chords: [.key("]", .option)], menu: .playback, enablement: .track,
            note: "Back to the original key")
    ]

    private static func preset(_ id: ActionID, _ title: String, _ key: Character) -> ActionEntry {
        ActionEntry(
            id, title, .speed, chords: [.key(key)], menu: .playback, enablement: .track,
            kind: .toggle)
    }

    // MARK: - Playback ▸ volume

    static let volumeEntries: [ActionEntry] = [
        ActionEntry(
            .volumeUp, "Volume Up", .volume,
            chords: [KeyChord(.upArrow)], menu: .playback, enablement: .track),
        ActionEntry(
            .volumeDown, "Volume Down", .volume,
            chords: [KeyChord(.downArrow)], menu: .playback, enablement: .track),
        ActionEntry(
            .volumeUpFine, "Volume Up (Fine)", .volume,
            chords: [KeyChord(.upArrow, .shift)], menu: .playback, enablement: .track),
        ActionEntry(
            .volumeDownFine, "Volume Down (Fine)", .volume,
            chords: [KeyChord(.downArrow, .shift)], menu: .playback, enablement: .track),
        ActionEntry(
            .volumeMute, "Mute", .volume,
            chords: [.key("m")], menu: .playback, enablement: .track, kind: .toggle)
    ]

    // MARK: - Edit ▸ selection

    static let selectionEntries: [ActionEntry] = [
        ActionEntry(
            .selectionSelectAll, "Select All", .selection,
            chords: [.key("a", .command)], menu: .edit, enablement: .track),
        ActionEntry(
            .selectionClear, "Clear Selection", .selection,
            chords: [KeyChord(.escape)], menu: .edit, enablement: .track),
        // On the arrows ⇧ extends the selection, following the macOS
        // text-editing convention; on Z/X it means a finer step. Spec §6.2
        // records why the two clusters differ on purpose.
        ActionEntry(
            .selectionExtendLeft, "Extend Selection Left", .selection,
            chords: [KeyChord(.leftArrow, .shift)], menu: .edit, enablement: .track),
        ActionEntry(
            .selectionExtendRight, "Extend Selection Right", .selection,
            chords: [KeyChord(.rightArrow, .shift)], menu: .edit, enablement: .track),
        ActionEntry(
            .selectionMoveLeft, "Move Selection Left", .selection,
            chords: [.key("c")], menu: .edit, enablement: .track),
        ActionEntry(
            .selectionMoveRight, "Move Selection Right", .selection,
            chords: [.key("v")], menu: .edit, enablement: .track),
        ActionEntry(
            .selectionMoveLeftFar, "Move Selection Left (Far)", .selection,
            chords: [.key("c", .option)], menu: .edit, enablement: .track),
        ActionEntry(
            .selectionMoveRightFar, "Move Selection Right (Far)", .selection,
            chords: [.key("v", .option)], menu: .edit, enablement: .track)
    ]

    // MARK: - View

    static let viewEntries: [ActionEntry] = [
        ActionEntry(.zoomFit, "Fit Whole File", .view, chords: [.key("0", .command)], menu: .view),
        ActionEntry(
            // Enablement deliberately left at the default, matching `zoomFit`
            // beside it. An earlier version greyed this out via a
            // `trackZoomTarget` case, which *also* required the document window
            // to hold the keyboard — so after any run that opened the shortcut
            // window, ⌘9 silently did nothing while ⌘0 still worked. Greying out
            // "there is nothing to zoom to" was a nicety; making one of two
            // adjacent zoom commands focus-sensitive and the other not was a
            // bug. The command guards itself.
            .zoomToSelection, "Zoom to Selection", .view,
            chords: [.key("9", .command)], menu: .view,
            note: "Falls back to the loop when nothing is selected"),
        ActionEntry(
            .zoomIn, "Zoom In", .view,
            chords: [.key("r")], menu: .view, enablement: .documentKey),
        ActionEntry(
            .zoomOut, "Zoom Out", .view,
            chords: [.key("e")], menu: .view, enablement: .documentKey),
        // No key equivalents: Z/X are the nudge keys, and a nudge brings the
        // view with it, so moving the view alone is left to these items, the
        // trackpad and the overview strip.
        ActionEntry(.viewScrollLeft, "Scroll Left", .view, menu: .view, enablement: .documentKey),
        ActionEntry(.viewScrollRight, "Scroll Right", .view, menu: .view, enablement: .documentKey),
        // Task 27's cue-sheet track marks. A `.toggle`, so the menu shows
        // whether the lane is up rather than switching its own title between
        // "Show" and "Hide" — the checkmark is what macOS already uses for a
        // mode. `T` for Track, and it was unbound on every layer.
        ActionEntry(
            .viewTrackMarksToggle, "Track Marks", .view,
            chords: [.key("t")], menu: .view, enablement: .track, kind: .toggle,
            note: "Where each track starts, from the album's .cue sheet"),
        ActionEntry(
            .helpShortcuts, "Keyboard Shortcuts", .view,
            chords: [.key("/", .command)], menu: .view),
        // Task 21's Practice hub. In **View**, beside Keyboard Shortcuts,
        // because what this item does is open a window — the ramp itself is in
        // the Loop menu, where the feature belongs. `⌘P` is free: this app has
        // no Print command and never will, since there is nothing here to print.
        ActionEntry(
            .practiceShow, "Practice", .view,
            chords: [.key("p", .command)], menu: .view,
            note: "The ramping loop — practise a passage from slow to tempo")
    ]

    // MARK: - Loop ▸ the practice ramp

    /// Start and stop the ramp without leaving the waveform.
    ///
    /// A `.toggle`, so the item shows whether a ramp is running rather than
    /// having to switch its own title between two verbs — the checkmark is what
    /// macOS already uses to say "this mode is on".
    ///
    /// In the **Loop** menu rather than beside its window in View: this is the
    /// signature feature's newest half, `LoopCommands` was built with room for
    /// it, and a ramp is a thing done to a loop.
    ///
    /// `⌥P` pairs with the window's `⌘P` on the same letter — `⌘` opens the
    /// thing, `⌥` runs it — which is the only mnemonic available for a feature
    /// whose name begins with a letter the loop row does not contain. `P` was
    /// unbound on every layer before this.
    static let practiceEntries: [ActionEntry] = [
        ActionEntry(
            .practiceRampToggle, "Speed Ramp", .loop,
            chords: [.key("p", .option)], menu: .loop, enablement: .trackLoop, kind: .toggle,
            note: "Set it up in the Practice window (⌘P)")
    ]

    // MARK: - File

    static let fileEntries: [ActionEntry] = [
        ActionEntry(.fileOpen, "Open…", .file, chords: [.key("o", .command)], menu: .fileOpen),
        ActionEntry(.fileSave, "Save", .file, chords: [.key("s", .command)], menu: .fileSave),
        ActionEntry(
            .fileSaveAs, "Save As…", .file,
            chords: [.key("s", [.shift, .command])], menu: .fileSave)
    ]

    // MARK: - Application

    /// Cut, Copy and Paste exist for exactly one place — the numeric fields in
    /// Settings. Artscribe replaces the standard pasteboard group, so without
    /// them ⌘C and ⌘V would quietly stop working while typing an amount.
    static let applicationEntries: [ActionEntry] = [
        ActionEntry(
            .editCut, "Cut", .application,
            chords: [.key("x", .command)], menu: .edit, note: "In text fields"),
        ActionEntry(
            .editCopy, "Copy", .application,
            chords: [.key("c", .command)], menu: .edit, note: "In text fields"),
        ActionEntry(
            .editPaste, "Paste", .application,
            chords: [.key("v", .command)], menu: .edit, note: "In text fields"),
        // Placed by SwiftUI's `Settings` scene, in the app menu — see
        // `ActionCatalog.notInOurMenus`.
        ActionEntry(
            .appSettings, "Settings…", .application,
            chords: [.key(",", .command)], menu: nil, note: "Artscribe ▸ Settings…"),
        // Placed into two menus macOS already builds — the app menu's About item
        // and the Help menu's — rather than into a `MenuPlan` section of ours.
        // See `ActionCatalog.notInOurMenus` and `ViewerCommands`.
        //
        // Unbound, and listed here anyway: since Task 25 the reference stopped
        // skipping actions with no chord, because a window headed "Keyboard
        // Shortcuts" that cannot find an item at all sends you hunting through
        // the menu bar for it. The privacy policy is the one thing in this app a
        // reader may be *required* to find (guideline 5.1.1(i)), so it is the
        // last thing that should be missing from the index of what exists.
        ActionEntry(
            .appAbout, "About Artscribe", .application,
            menu: nil, note: "Artscribe ▸ About Artscribe")
    ]
}
