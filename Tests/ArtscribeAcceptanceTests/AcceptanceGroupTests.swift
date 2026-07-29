import Testing

@testable import ArtscribeAcceptance

/// The group-selection logic in front of the acceptance harness, as pure logic.
///
/// The harness itself needs a window, an audio file and minutes of wall clock;
/// deciding which slice of it to run needs none of those, and this is the part
/// that must not be wrong. A `--only` that silently ran nothing, or a typo that
/// silently ran everything, would turn "acceptance passed" into a lie — so the
/// cases below are mostly about the ways it must refuse.
private typealias Group = AcceptanceRun.CheckGroup
private typealias Plan = AcceptanceRun.Plan
private typealias PlanError = AcceptanceRun.PlanError

private func plan(_ arguments: String...) -> Result<Plan, PlanError> {
    AcceptanceRun.parsePlan(from: ["ArtscribeAcceptance"] + arguments)
}

private func groups(_ arguments: String...) throws -> Set<Group> {
    try AcceptanceRun.parsePlan(from: ["ArtscribeAcceptance"] + arguments).get().groups
}

@Suite struct AcceptanceGroupTests {

    @Test func aBareCommandLineRunsEverything() throws {
        let plan = try AcceptanceRun.parsePlan(
            from: ["ArtscribeAcceptance", "--acceptance", "/tmp/a.wav"]
        ).get()
        #expect(plan.groups == Set(Group.allCases))
        #expect(plan.isComplete)
        #expect(plan.notRun.isEmpty)
    }

    @Test func onlyRunsExactlyWhatItNames() throws {
        #expect(try groups("--only", "transport,loop") == [.transport, .loop])
    }

    @Test func onlyIsNotComplete() throws {
        let plan = try AcceptanceRun.parsePlan(
            from: ["ArtscribeAcceptance", "--only", "transport"]
        ).get()
        #expect(!plan.isComplete)
        #expect(plan.ran == [.transport])
        #expect(plan.notRun.count == Group.allCases.count - 1)
    }

    @Test func skipRemovesFromEverythingElse() throws {
        let selected = try groups("--skip", "playback,session")
        #expect(selected == Set(Group.allCases).subtracting([.playback, .session]))
    }

    /// `--only` chooses the field, `--skip` then narrows it. The other reading —
    /// `--skip` being ignored when `--only` is present — would silently run a
    /// group the caller explicitly excluded.
    @Test func onlyAndSkipIntersect() throws {
        #expect(try groups("--only", "menu,loop,zoom", "--skip", "loop") == [.menu, .zoom])
    }

    @Test func quickDropsExactlyTheSlowGroups() throws {
        let selected = try groups("--quick")
        #expect(selected == Set(Group.allCases.filter { !$0.isSlow }))
        #expect(!selected.contains(.playback))
        #expect(!selected.contains(.start))
        #expect(selected.contains(.loop), "loop moves are keystrokes, not timed playback")
    }

    @Test func quickNarrowsAnOnlySelectionToo() throws {
        #expect(try groups("--only", "menu,playback", "--quick") == [.menu])
    }

    /// Names are typed by hand at a shell, so the shapes a hand produces parse.
    @Test func namesTolerateSpacingAndCase() throws {
        #expect(try groups("--only", " Transport , LOOP ,,") == [.transport, .loop])
    }

    /// Repeating a flag unions rather than dropping all but the first, which is
    /// what reading only the first occurrence would have done.
    @Test func repeatedOnlyFlagsUnion() throws {
        #expect(try groups("--only", "menu", "--only", "loop") == [.menu, .loop])
    }

    // MARK: - Refusals

    @Test func anUnknownGroupIsFatal() {
        let expected = PlanError.unknownGroups(flag: "--only", names: ["trasnport"])
        #expect(plan("--only", "trasnport") == .failure(expected))
    }

    /// Both typos, not just the first: being told about one and then hitting the
    /// other on the retry is two minutes for no reason.
    @Test func everyUnknownGroupIsReported() {
        let expected = PlanError.unknownGroups(flag: "--only", names: ["trasnport", "menue"])
        #expect(plan("--only", "trasnport,loop,menue") == .failure(expected))
    }

    @Test func anUnknownSkipIsFatalToo() {
        let expected = PlanError.unknownGroups(flag: "--skip", names: ["playbak"])
        #expect(plan("--skip", "playbak") == .failure(expected))
    }

    /// A flag typed last, with nothing after it, must not be read as "no
    /// restriction" — that would run the whole list when a subset was asked for.
    @Test func aFlagWithNoValueIsFatal() {
        #expect(plan("--only") == .failure(.noNames(flag: "--only")))
        #expect(plan("--skip") == .failure(.noNames(flag: "--skip")))
    }

    @Test func aFlagWithAnEmptyListIsFatal() {
        #expect(plan("--only", " , ,") == .failure(.noNames(flag: "--only")))
    }

    @Test func flagsThatSelectNothingAreFatal() {
        #expect(plan("--only", "playback", "--skip", "playback") == .failure(.nothingSelected))
        #expect(plan("--only", "playback,start", "--quick") == .failure(.nothingSelected))
    }

    @Test func everyErrorNamesTheValidGroups() {
        let errors: [PlanError] = [
            .noNames(flag: "--only"),
            .unknownGroups(flag: "--only", names: ["nope"]),
            .nothingSelected
        ]
        for error in errors {
            #expect(error.message.contains("--list"))
            for group in Group.allCases {
                #expect(
                    error.message.contains(group.rawValue),
                    "\(error) should name '\(group.rawValue)' so a typo is recoverable")
            }
        }
    }

    // MARK: - Reporting

    /// The reason has to be the flag that actually made the decision, because
    /// the summary prints it and a wrong one sends the reader to the wrong flag.
    @Test func theReasonNamesTheFlagThatExcludedTheGroup() throws {
        let onlyMenu = try AcceptanceRun.parsePlan(
            from: ["x", "--only", "menu"]).get()
        #expect(onlyMenu.reason(notRunning: .playback).contains("--only"))

        let skipped = try AcceptanceRun.parsePlan(from: ["x", "--skip", "playback"]).get()
        #expect(skipped.reason(notRunning: .playback).contains("--skip"))

        let quick = try AcceptanceRun.parsePlan(from: ["x", "--quick"]).get()
        #expect(quick.reason(notRunning: .playback).contains("--quick"))

        // `--skip` wins over `--quick` when both would have excluded it, because
        // `--skip` is the one the caller typed about this group specifically.
        let both = try AcceptanceRun.parsePlan(from: ["x", "--skip", "playback", "--quick"]).get()
        #expect(both.reason(notRunning: .playback).contains("--skip"))
    }

    @Test func groupNamesAreShortAndDistinct() {
        let names = Group.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.count <= 10, "'\(name)' is too long to type from memory")
            #expect(name == name.lowercased())
        }
    }

    /// `--list` is the only discovery path that does not involve reading the
    /// harness's source, so every group has to appear in it with a description.
    @Test func listingCoversEveryGroup() {
        let listing = AcceptanceRun.groupListing()
        for group in Group.allCases {
            #expect(listing.contains(group.rawValue))
            #expect(listing.contains(group.summary))
            #expect(!group.summary.isEmpty)
        }
        #expect(listing.contains("--only"))
        #expect(listing.contains("--skip"))
        #expect(listing.contains("--quick"))
        #expect(listing.contains("SLOW"))
        #expect(listing.contains("exits 2"))
    }
}

/// The exit status, which is the only thing an automated caller reads. A
/// partial run reported as 0 is the failure mode this whole task exists to
/// prevent.
@Suite struct AcceptanceExitCodeTests {

    @Test func aCleanCompleteRunExitsZero() {
        var log = AcceptanceRun.Logger(plan: .everything)
        log.check("something", true)
        #expect(log.exitCode == 0)
    }

    @Test func aFailureExitsOne() {
        var log = AcceptanceRun.Logger(plan: .everything)
        log.check("something", false)
        #expect(log.exitCode == 1)
    }

    @Test func anEnvironmentSkipExitsTwo() {
        var log = AcceptanceRun.Logger(plan: .everything)
        log.check("something", true)
        log.skip("something else", because: "no audio device")
        #expect(log.exitCode == 2)
    }

    /// The new case: nothing failed, nothing was environment-skipped, and the
    /// run still must not claim a pass, because it only ran one group.
    @Test func aPartialRunNeverExitsZero() throws {
        let plan = try AcceptanceRun.parsePlan(from: ["x", "--only", "menu"]).get()
        var log = AcceptanceRun.Logger(plan: plan)
        let ranMenu = log.running(.menu)
        #expect(ranMenu)
        log.check("a menu thing", true)
        #expect(log.exitCode == 2)
    }

    @Test func aPartialRunWithAFailureStillExitsOne() throws {
        let plan = try AcceptanceRun.parsePlan(from: ["x", "--quick"]).get()
        var log = AcceptanceRun.Logger(plan: plan)
        log.check("a thing", false)
        #expect(log.exitCode == 1)
    }

    /// `running` is both the gate and the timer, so it has to answer the plan
    /// rather than run everything it is handed.
    @Test func runningGatesOnThePlan() throws {
        let plan = try AcceptanceRun.parsePlan(from: ["x", "--only", "menu"]).get()
        var log = AcceptanceRun.Logger(plan: plan)
        let menu = log.running(.menu)
        let playback = log.running(.playback)
        let session = log.running(.session)
        #expect(menu)
        #expect(!playback)
        #expect(!session)
    }
}
