// Shared os.Logger instances. HIDE/SHOW decisions, warnings, and the
// adapter subprocess's stderr funnel through here so everything is
// queryable via `houdini logs` (which wraps `log stream`) or
// Console.app filtering by subsystem.

import os

enum Log {
    static let subsystem = "com.github.mgxv.houdini"

    /// HIDE/SHOW decisions emitted by the evaluation loop.
    static let controller = Logger(subsystem: subsystem, category: "controller")

    /// mediaremote-adapter subprocess output. Logged at `.debug` so it
    /// stays out of the default `houdini logs` stream — surface it with
    /// `log stream --level debug` when diagnosing the subprocess.
    static let adapter = Logger(subsystem: subsystem, category: "adapter")

    /// Startup/shutdown notices and everything routed through `warn`/`die`.
    static let general = Logger(subsystem: subsystem, category: "general")
}
