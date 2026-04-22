// Isolates the @preconcurrency import of ApplicationServices to the
// single place that actually needs it: reading kAXTrustedCheckOptionPrompt,
// a CFString const the AX headers declare as a non-Sendable `var`. Any
// other AX symbol used elsewhere imports ApplicationServices without
// @preconcurrency and goes through full Sendable checking — a new
// @preconcurrency-suppressed read anywhere else is grep-visible because
// this file is the sole place the attribute appears.

@preconcurrency import ApplicationServices

/// String form of the AX "prompt if not already trusted" option key.
/// `@MainActor` because the only caller (`ensureAccessibilityPermission`)
/// is @MainActor and reads this once at process startup.
@MainActor
let axTrustedCheckOptionPromptKey: String =
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
