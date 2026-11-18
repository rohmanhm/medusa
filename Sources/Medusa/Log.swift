import Foundation
import os

/// Medusa's trail in the unified log: every lock, unlock attempt, session
/// event, and keep-awake change, so a field report ("the dialog didn't come
/// up") can be replayed instead of guessed at.
///
///     log show --last 1h --predicate 'subsystem == "org.medusa.Medusa"'
///
/// Local builds log under `org.medusa.Medusa.local`.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "org.medusa.Medusa"

    static let lock = Logger(subsystem: subsystem, category: "lock")
    static let keepAwake = Logger(subsystem: subsystem, category: "keepawake")
}
