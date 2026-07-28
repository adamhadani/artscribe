import Foundation

extension AcceptanceRun {

    struct Logger {
        private(set) var failures = 0
        /// Checks the machine could not support. Counted apart from failures and
        /// from passes, because they are neither.
        private(set) var skipped = 0
        private var lines: [String] = []

        mutating func check(_ name: String, _ passed: Bool) {
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

        /// 0 = everything was checked and passed, 1 = something failed,
        /// 2 = nothing failed but some checks could not run. A caller that reads
        /// only the exit status still cannot mistake a partly-run acceptance for
        /// a complete one.
        var exitCode: Int32 {
            if failures > 0 { return 1 }
            return skipped > 0 ? 2 : 0
        }

        func report() {
            print("\n===== ACCEPTANCE =====")
            for line in lines { print(line) }
            let summary =
                skipped > 0
                ? "\(failures) failure(s), \(skipped) NOT CHECKED"
                : "\(failures) failure(s)"
            print("===== \(summary) =====\n")
        }
    }
}
