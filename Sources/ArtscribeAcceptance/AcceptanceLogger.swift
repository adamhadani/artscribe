import Foundation

extension AcceptanceRun {

    /// Accumulated across every opening of a group, because a group is not
    /// necessarily one contiguous stretch of the run.
    fileprivate struct GroupTotal {
        var seconds = 0.0
        var checks = 0
    }

    /// The group `Logger` is currently timing, and where it started.
    fileprivate struct OpenGroup {
        let group: CheckGroup
        let started: Date
        let checksBefore: Int
    }

    struct Logger {
        private(set) var failures = 0
        /// Checks the machine could not support. Counted apart from failures and
        /// from passes, because they are neither.
        private(set) var skipped = 0
        /// Which groups this run was asked to execute. A `Logger` that does not
        /// know cannot report what was left out, and a run that does not report
        /// what it left out is a partial acceptance wearing a pass's clothes.
        let plan: Plan
        private var lines: [String] = []
        /// Every check and skip recorded so far, used to attribute counts to the
        /// group that was open when they happened.
        private var recorded = 0
        private var totals: [CheckGroup: GroupTotal] = [:]
        private var open: OpenGroup?
        private let started = Date()

        init(plan: Plan) {
            self.plan = plan
        }

        mutating func check(_ name: String, _ passed: Bool) {
            recorded += 1
            if !passed { failures += 1 }
            lines.append("\(passed ? "PASS" : "FAIL")  \(name)")
        }

        /// A check this session cannot support, with the reason it cannot.
        ///
        /// Spec §8 — never degrade silently — applies to the harness as much as
        /// to the app. The alternative that keeps suggesting itself, relaxing an
        /// assertion until the environment stops tripping it, is how a real
        /// defect becomes permanent; this records what was not checked instead.
        /// The reason must be established *independently* of the behaviour under
        /// test, or a skip is just a failure in a better mood.
        mutating func skip(_ name: String, because reason: String) {
            recorded += 1
            skipped += 1
            lines.append("SKIP  \(name) — \(reason)")
        }

        /// `check`, unless `reason` says the environment cannot support it.
        mutating func check(_ name: String, _ passed: Bool, unless reason: String?) {
            guard let reason else { return check(name, passed) }
            skip(name, because: reason)
        }

        mutating func note(_ name: String, _ value: String) {
            lines.append("....  \(name): \(value)")
        }

        // MARK: - Groups

        /// Opens `group` and says whether the run should execute it.
        ///
        /// Closing is implicit: each call closes whatever was open, and so does
        /// `report()`. An explicit `end` would be one more thing to forget at
        /// the bottom of a block, and forgetting it would silently misattribute
        /// the next group's time.
        ///
        /// A group may be opened more than once — `menu` and `edge` are each two
        /// stretches of the run, separated by checks that must sit between them
        /// — and its time and check count accumulate across the openings.
        mutating func running(_ group: CheckGroup) -> Bool {
            closeGroup()
            guard plan.runs(group) else { return false }
            lines.append("====  \(group.rawValue)")
            open = OpenGroup(group: group, started: Date(), checksBefore: recorded)
            return true
        }

        private mutating func closeGroup() {
            guard let open else { return }
            var total = totals[open.group] ?? GroupTotal()
            total.seconds += Date().timeIntervalSince(open.started)
            total.checks += recorded - open.checksBefore
            totals[open.group] = total
            self.open = nil
        }

        // MARK: - Result

        /// 0 = every group ran, everything was checked and passed. 1 = something
        /// failed. 2 = nothing failed but the run was not complete — either the
        /// machine could not support some checks, or `--only`/`--skip`/`--quick`
        /// left groups out. A caller that reads only the exit status still
        /// cannot mistake a partly-run acceptance for a complete one.
        var exitCode: Int32 {
            if failures > 0 { return 1 }
            return (skipped > 0 || !plan.isComplete) ? 2 : 0
        }

        mutating func report() {
            closeGroup()
            print("\n===== ACCEPTANCE =====")
            for line in lines { print(line) }
            for line in groupTable() { print(line) }
            print("===== \(summaryLine()) =====\n")
        }

        /// What ran, what it cost, and — named individually — what did not.
        private func groupTable() -> [String] {
            let width = CheckGroup.allCases.map(\.rawValue.count).max() ?? 10
            var lines = ["", "----- GROUPS -----"]
            for group in CheckGroup.allCases {
                let name = group.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
                if let total = totals[group] {
                    lines.append(
                        String(
                            format: "ran      %@  %4d checks  %7.1f s", name, total.checks,
                            total.seconds))
                } else if plan.runs(group) {
                    lines.append("ran      \(name)     0 checks  (nothing to check)")
                } else {
                    lines.append("NOT RUN  \(name)  — \(plan.reason(notRunning: group))")
                }
            }
            // `recorded` rather than the sum of the rows: the load and window
            // checks in front of the first group belong to no group and would
            // otherwise vanish from the total.
            lines.append(
                String(
                    format: "total    %d of %d groups, %d checks (incl. prelude), %.1f s wall "
                        + "clock",
                    plan.ran.count, CheckGroup.allCases.count, recorded,
                    Date().timeIntervalSince(started)))
            lines.append("")
            return lines
        }

        /// The last line anyone reads, so it has to be unambiguous about
        /// completeness. "0 failures" on a run that skipped two thirds of the
        /// list is the exact misreading this spells out instead.
        private func summaryLine() -> String {
            var parts = ["\(failures) failure(s)"]
            if skipped > 0 { parts.append("\(skipped) NOT CHECKED") }
            let missing = plan.notRun
            if !missing.isEmpty {
                parts.append(
                    "\(missing.count) of \(CheckGroup.allCases.count) group(s) NOT RUN "
                        + "(\(missing.map(\.rawValue).joined(separator: ", ")))")
            }
            let verdict =
                plan.isComplete
                ? (skipped > 0 ? "every group ran, some checks could not" : "every group ran")
                : "PARTIAL RUN — NOT AN ACCEPTANCE PASS"
            return parts.joined(separator: ", ") + " — " + verdict
        }
    }
}
