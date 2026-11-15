import AssistantCore
import Foundation

actor RunnerCommerceMessageObserver {
    private let bridge: RunnerAppUIBridge
    private var loopTask: Task<Void, Never>?
    private var running = false
    private var lastSignature: [UInt8]?
    private var lastForegroundBundleID: String?
    private var lastPageReadAt = Date.distantPast
    private var nextCompensationReadAt = Date()
    private var compensationInterval: TimeInterval = 3
    private var detectedAt: [String: Date] = [:]

    init(bridge: RunnerAppUIBridge) {
        self.bridge = bridge
    }

    func start(
        handler: @escaping @Sendable (DetectedCommerceMessage) async throws -> Void
    ) {
        guard !running else {
            return
        }
        running = true
        loopTask = Task { [weak self] in
            await self?.run(handler: handler)
        }
    }

    func stop() {
        running = false
        loopTask?.cancel()
        loopTask = nil
    }

    private func run(
        handler: @escaping @Sendable (DetectedCommerceMessage) async throws -> Void
    ) async {
        iCTRLUITests.logBuffer.append(
            "Commerce observer started; page reads are change-triggered, "
                + "with adaptive failure compensation"
        )
        while running && !Task.isCancelled {
            let cycleStarted = Date()
            do {
                let signature = try await bridge.screenSignature()
                let now = Date()
                let changed: Bool
                if let signature, let lastSignature {
                    let changeThreshold =
                        lastForegroundBundleID == "com.apple.springboard"
                            ? 0.08
                            : 0.03
                    changed = ScreenSettle.changedShare(
                        lastSignature,
                        signature
                    ) >= changeThreshold
                } else {
                    changed = false
                }
                let firstRead = lastSignature == nil && signature != nil
                let compensationDue = now >= nextCompensationReadAt
                let canRead = now.timeIntervalSince(lastPageReadAt) >= 0.5
                if canRead && (changed || firstRead || compensationDue) {
                    let page = try await bridge.foregroundPage()
                    lastForegroundBundleID = page.bundleID
                    let messages = CommerceMessageDetector.parse(
                        bundleID: page.bundleID,
                        snapshot: page.snapshot
                    )
                    for message in messages {
                        guard !recentlyDetected(message.notificationKey)
                        else {
                            continue
                        }
                        do {
                            try await handler(message)
                            detectedAt[message.notificationKey] = now
                            iCTRLUITests.logBuffer.append(
                                "Commerce event accepted: "
                                    + "platform=\(message.platform.rawValue) "
                                    + "source=\(message.source.rawValue) "
                                    + "store_chars=\(message.storeName.count) "
                                    + "notice_prefix="
                                    + String(message.notificationKey.prefix(8))
                            )
                            // A notification tap changes the screen. Process
                            // one event per page snapshot, then re-read before
                            // using any other coordinates.
                            break
                        } catch {
                            iCTRLUITests.logBuffer.append(
                                "Commerce event enqueue failed: "
                                    + "source=\(message.source.rawValue) "
                                    + "error=\(String(describing: error))"
                            )
                        }
                    }
                    lastPageReadAt = now
                    nextCompensationReadAt = now.addingTimeInterval(20)
                    compensationInterval = 3
                    pruneDetected(now)
                }
                lastSignature = signature
            } catch {
                compensationInterval = min(
                    60,
                    max(3, compensationInterval * 2)
                )
                nextCompensationReadAt = Date().addingTimeInterval(
                    compensationInterval
                )
                iCTRLUITests.logBuffer.append(
                    "Commerce observer read failed; retry in "
                        + "\(Int(compensationInterval))s: "
                        + String(describing: error)
                )
            }

            let elapsed = Date().timeIntervalSince(cycleStarted)
            let remaining = max(0.05, 0.4 - elapsed)
            try? await Task.sleep(
                nanoseconds: UInt64(remaining * 1_000_000_000)
            )
        }
        iCTRLUITests.logBuffer.append("Commerce observer stopped")
    }

    private func recentlyDetected(_ key: String) -> Bool {
        guard let at = detectedAt[key] else {
            return false
        }
        return Date().timeIntervalSince(at) < 15 * 60
    }

    private func pruneDetected(_ now: Date) {
        detectedAt = detectedAt.filter {
            now.timeIntervalSince($0.value) < 60 * 60
        }
    }
}
