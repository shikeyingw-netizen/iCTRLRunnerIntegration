import AssistantCore
import Foundation

/// Process-wide, fail-closed gate in front of every phone-control action.
///
/// The persisted SQLite row is the source of truth across restarts. The cached
/// value exists so already-queued RPC work and long-running automation tasks can
/// observe a manual takeover on their very next action without waiting for the
/// UI queue.
final class AutomationControlGate: @unchecked Sendable {
    static let shared = AutomationControlGate()

    private let lock = NSLock()
    private var store: SQLiteAutomationControlStore?
    private var cached = AutomationControlRecord(
        state: .humanTakeover,
        generation: 1,
        updatedAt: Date(timeIntervalSince1970: 0),
        actor: "system",
        reason: "Fail closed until SQLite state is loaded"
    )
    private var stateChangeHandler:
        (@Sendable (AutomationControlRecord) -> Void)?

    private init() {}

    @discardableResult
    func bootstrap() throws -> AutomationControlRecord {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(
            "RunnerCustomerService",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        let newStore = try SQLiteAutomationControlStore(
            databaseURL: base.appendingPathComponent(
                "automation-control.sqlite"
            )
        )
        let loaded = try newStore.current()
        lock.lock()
        store = newStore
        cached = loaded
        let handler = stateChangeHandler
        lock.unlock()
        handler?(loaded)
        return loaded
    }

    var isBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cached.state.blocksPhoneControl
    }

    var status: AutomationControlRecord {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func setStateChangeHandler(
        _ handler: (@Sendable (AutomationControlRecord) -> Void)?
    ) {
        lock.lock()
        stateChangeHandler = handler
        let current = cached
        lock.unlock()
        handler?(current)
    }

    @discardableResult
    func engageHumanTakeover(
        reason: String,
        actor: String = "user"
    ) throws -> AutomationControlRecord {
        try transition(
            to: .humanTakeover,
            reason: reason,
            actor: actor
        )
    }

    @discardableResult
    func pauseAutomation(
        reason: String,
        actor: String = "user"
    ) throws -> AutomationControlRecord {
        try transition(
            to: .automationPaused,
            reason: reason,
            actor: actor
        )
    }

    @discardableResult
    func requestManualResume(
        reason: String,
        actor: String = "user"
    ) throws -> AutomationControlRecord {
        try transition(
            to: .awaitingManualResume,
            reason: reason,
            actor: actor
        )
    }

    @discardableResult
    func confirmAutomaticAfterPreflight(
        reason: String,
        actor: String = "user"
    ) throws -> AutomationControlRecord {
        try transition(
            to: .automatic,
            reason: reason,
            actor: actor
        )
    }

    func blockMessage(method: String) -> String {
        let current = status
        return "Automation control is locked (\(current.state.rawValue), "
            + "generation \(current.generation)); refused \(method). "
            + "Physical/manual use of the phone is allowed. Resume requires "
            + "the on-device explicit approval flow."
    }

    private func transition(
        to target: AutomationControlState,
        reason: String,
        actor: String
    ) throws -> AutomationControlRecord {
        lock.lock()
        guard let store else {
            let fallback = AutomationControlRecord(
                state: .humanTakeover,
                generation: cached.generation + 1,
                updatedAt: Date(),
                actor: actor,
                reason: reason
            )
            cached = fallback
            let handler = stateChangeHandler
            lock.unlock()
            handler?(fallback)
            throw NSError(
                domain: "AutomationControlGate",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Persistent automation-control store is unavailable; "
                        + "the in-memory gate remains locked."
                ]
            )
        }
        lock.unlock()

        // Publish blocking states immediately, before SQLite I/O, so an
        // already-running task cannot squeeze another tap through.
        if target.blocksPhoneControl {
            lock.lock()
            let urgent = AutomationControlRecord(
                state: target,
                generation: cached.generation + 1,
                updatedAt: Date(),
                actor: actor,
                reason: reason
            )
            cached = urgent
            let handler = stateChangeHandler
            lock.unlock()
            handler?(urgent)
        }

        let persisted = try store.update(
            to: target,
            actor: actor,
            reason: reason
        )
        lock.lock()
        cached = persisted
        let handler = stateChangeHandler
        lock.unlock()
        handler?(persisted)
        return persisted
    }
}
