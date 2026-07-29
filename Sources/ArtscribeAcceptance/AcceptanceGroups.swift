import Foundation

/// Selective acceptance runs: the harness's equivalent of `swift test --filter`
/// and `xcodebuild -only-testing`.
///
/// A full run drives a live window through roughly six hundred checks with real
/// timed playback in the middle of it, which is minutes of wall clock. An agent
/// verifying a one-line change to the Loop menu should not pay for the loop
/// audio, and before this it had no choice.
///
/// The groups below are the run's existing structure named, not a second
/// taxonomy laid over it — each one is a contiguous stretch of `AcceptanceRun`
/// that already set its own state up and already cleaned up after itself.
///
/// The rule this has to respect is spec §8's: nothing degrades silently. A
/// partial run is not an acceptance pass, so `Plan` travels into `Logger`, the
/// summary names what did not run and why, and the exit status is 2 rather than
/// 0 for any run that was not complete.
extension AcceptanceRun {

    /// A separately runnable slice of the acceptance list.
    ///
    /// Declaration order is run order, which is also the order `--list` prints.
    enum CheckGroup: String, CaseIterable, Sendable {
        case pointer
        case cursor
        case edge
        case zoom
        case theme
        case menu
        case shortcuts
        case transport
        case navigation
        case selection
        case loop
        case playback
        case start
        case session
        case window
        case catalog
        case practice

        /// One line, for `--list`. This is the only documentation of what a
        /// group covers that someone selecting one will actually read, so it
        /// names behaviour rather than function names.
        var summary: String {
            switch self {
            case .pointer: "real pointer drags in the ruler and the waveform lanes"
            case .cursor: "the cursors that advertise the zoom and drag gestures"
            case .edge: "dragging loop and selection edges, hovering them, and mid-playback"
            case .zoom: "zoom anchoring, deep zoom, pan clamping, trackpad, wheel, drag, direction"
            case .theme: "the speed readout's emphasis and the three theme settings"
            case .menu: "File, View, Edit and Loop menus, Open Recent, and item enablement"
            case .shortcuts:
                "key-equivalent presentation, menu-bar strobe, single-fire, text fields"
            case .transport: "the transport bar's buttons, focus, and the loop button's prominence"
            case .navigation:
                "Z/X nudge tiers, their clamps and menu items, and the Settings window"
            case .selection: "drag to select, zoom to selection, moving and extending a selection"
            case .loop: "moving the whole loop, its walls, and its inversion guard"
            case .playback: "transport, volume, speed, seamless looping, auto-scroll, Playback menu"
            case .start: "Shift-Space's precedence rule and double-click-to-play"
            case .session: "the .artscribe sidecar: save, reopen, corruption, read-only fallback"
            case .window: "window resize, and the banner a file that cannot be decoded raises"
            case .catalog: "the menu bar against ActionCatalog, and the shortcut window (⌘/)"
            case .practice:
                "the Practice window (⌘P), and a speed ramp advancing on real loop wraps"
            }
        }

        /// True for the groups that spend their time waiting on real playback
        /// rather than on the checks themselves. These are what `--quick` drops,
        /// and between them they are most of a full run's wall clock.
        var isSlow: Bool {
            switch self {
            // `practice` plays a four-second loop three times over, at half
            // speed to start with; there is no way to watch a ramp advance on
            // real wraps that does not take real time.
            case .playback, .start, .practice: true
            default: false
            }
        }

        /// Roughly how many checks this group carries, for `--list`.
        ///
        /// Approximate on purpose and marked `~` where it is printed: several
        /// groups check a variable number of menu items, and a check the machine
        /// cannot support is recorded as a skip, which still counts here.
        /// Measured from a full run on 2026-07-28 (614 checks in 137 s) — refresh
        /// them from the per-group table a full run prints if they drift.
        var approximateChecks: Int {
            switch self {
            case .pointer: 5
            case .cursor: 1
            case .edge: 14
            case .zoom: 31
            case .theme: 16
            case .menu: 43
            case .shortcuts: 24
            case .transport: 20
            case .navigation: 42
            case .selection: 15
            case .loop: 20
            case .playback: 105
            case .start: 16
            case .session: 50
            case .window: 4
            case .catalog: 200
            case .practice: 28
            }
        }
    }

    /// Which groups a run will execute, and — for the ones it will not — which
    /// flag excluded them.
    struct Plan: Sendable, Equatable {
        /// `nil` when `--only` was not given, meaning "start from everything".
        let only: Set<CheckGroup>?
        /// The names `--skip` named.
        let excluded: Set<CheckGroup>
        /// `--quick`, which drops the slow groups on top of the two above.
        let quick: Bool

        /// The default: run the lot.
        static let everything = Plan(only: nil, excluded: [], quick: false)

        var groups: Set<CheckGroup> {
            var selected = only ?? Set(CheckGroup.allCases)
            selected.subtract(excluded)
            if quick { selected = selected.filter { !$0.isSlow } }
            return selected
        }

        func runs(_ group: CheckGroup) -> Bool { groups.contains(group) }

        /// Nothing was excluded, so a clean run is a real acceptance pass.
        var isComplete: Bool { groups.count == CheckGroup.allCases.count }

        /// In run order, so the report reads the way the run does.
        var ran: [CheckGroup] { CheckGroup.allCases.filter(groups.contains) }
        var notRun: [CheckGroup] { CheckGroup.allCases.filter { !groups.contains($0) } }

        /// Why `group` will not run. Checked in the order the flags are applied
        /// so the answer is the flag that actually made the decision.
        func reason(notRunning group: CheckGroup) -> String {
            if let only, !only.contains(group) { return "not named by --only" }
            if excluded.contains(group) { return "--skip" }
            if quick && group.isSlow { return "--quick (slow: real timed playback)" }
            return "not selected"
        }
    }

    /// A command line that cannot be honoured. Every case is fatal: silently
    /// running nothing, or running everything, in response to a typo is exactly
    /// the silent degradation this project refuses elsewhere.
    enum PlanError: Error, Equatable {
        case noNames(flag: String)
        case unknownGroups(flag: String, names: [String])
        case nothingSelected

        var message: String {
            switch self {
            case .noNames(let flag):
                "\(flag) needs a comma-separated list of group names. \(Self.validNames)"
            case .unknownGroups(let flag, let names):
                "\(flag): no such group \(names.map { "'\($0)'" }.joined(separator: ", ")). "
                    + Self.validNames
            case .nothingSelected:
                "the flags given leave no group to run, so there is nothing to check. "
                    + Self.validNames
            }
        }

        private static var validNames: String {
            "Valid groups: " + CheckGroup.allCases.map(\.rawValue).joined(separator: ", ")
                + ". Use --list for what each one covers."
        }
    }

    // MARK: - Parsing

    /// Every value that follows an occurrence of `flag`.
    ///
    /// All of them rather than the first, so `--only zoom --only menu` unions
    /// instead of quietly dropping one. A trailing `flag` with nothing after it
    /// contributes nothing rather than trapping.
    static func values(after flag: String, in args: [String]) -> [String] {
        var found: [String] = []
        for (index, argument) in args.enumerated() where argument == flag {
            if index + 1 < args.count { found.append(args[index + 1]) }
        }
        return found
    }

    /// Splits `--only a, b ,,C` into `["a", "b", "c"]`.
    static func groupNames(in values: [String]) -> [String] {
        values
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: true) }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Resolves names to groups, collecting *every* unknown one so a caller who
    /// mistyped two names is told about both.
    static func resolve(names: [String], flag: String) -> Result<Set<CheckGroup>, PlanError> {
        guard !names.isEmpty else { return .failure(.noNames(flag: flag)) }
        var groups: Set<CheckGroup> = []
        var unknown: [String] = []
        for name in names {
            if let group = CheckGroup(rawValue: name) {
                groups.insert(group)
            } else if !unknown.contains(name) {
                unknown.append(name)
            }
        }
        guard unknown.isEmpty else {
            return .failure(.unknownGroups(flag: flag, names: unknown))
        }
        return .success(groups)
    }

    /// The whole command line, as a plan. Pure: it reads nothing but `args`,
    /// which is what makes it testable without a window.
    static func parsePlan(from args: [String]) -> Result<Plan, PlanError> {
        var only: Set<CheckGroup>?
        if args.contains("--only") {
            let names = groupNames(in: values(after: "--only", in: args))
            switch resolve(names: names, flag: "--only") {
            case .success(let groups): only = groups
            case .failure(let error): return .failure(error)
            }
        }

        var excluded: Set<CheckGroup> = []
        if args.contains("--skip") {
            let names = groupNames(in: values(after: "--skip", in: args))
            switch resolve(names: names, flag: "--skip") {
            case .success(let groups): excluded = groups
            case .failure(let error): return .failure(error)
            }
        }

        let plan = Plan(only: only, excluded: excluded, quick: args.contains("--quick"))
        guard !plan.groups.isEmpty else { return .failure(.nothingSelected) }
        return .success(plan)
    }

    // MARK: - `--list`

    /// What `--list` prints. Built as a string rather than printed directly so
    /// the test can assert every group reaches it.
    static func groupListing() -> String {
        let width = CheckGroup.allCases.map(\.rawValue.count).max() ?? 10
        var lines = [
            "",
            "Acceptance groups — run a subset with --only or --skip, comma-separated:",
            "",
            "  swift run -c release ArtscribeAcceptance --acceptance <file> --only transport,loop",
            "  swift run -c release ArtscribeAcceptance --acceptance <file> --skip playback",
            "  swift run -c release ArtscribeAcceptance --acceptance <file> --quick",
            ""
        ]
        for group in CheckGroup.allCases {
            let name = group.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
            let count = "~\(group.approximateChecks)".padding(
                toLength: 5, withPad: " ", startingAt: 0)
            lines.append(
                "  \(name)  \(count)  \(group.isSlow ? "SLOW  " : "      ")\(group.summary)")
        }
        lines += [
            "",
            "SLOW groups wait on real timed playback and are most of a full run's wall clock;",
            "--quick drops them. Check counts are approximate — a full run prints the real ones.",
            "",
            "Any run that does not execute every group exits 2, never 0: a partial acceptance",
            "run is not an acceptance pass.",
            ""
        ]
        return lines.joined(separator: "\n")
    }
}
