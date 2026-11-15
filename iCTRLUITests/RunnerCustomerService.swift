import AssistantCore
import Foundation
import Security
import UserNotifications

enum RunnerCustomerServiceError: Error, CustomStringConvertible {
    case responseMissing(String)
    case wrongForegroundApp(expected: String, actual: String)
    case rpc(String)
    case unsupportedSurface

    var description: String {
        switch self {
        case let .responseMissing(field):
            return "iCTRL response did not contain \(field)"
        case let .wrongForegroundApp(expected, actual):
            return "Foreground app changed: expected \(expected), got \(actual)"
        case let .rpc(message):
            return "iCTRL action failed: \(message)"
        case .unsupportedSurface:
            return "The conversation is not in a verified direct-chat state"
        }
    }
}

final class RunnerAppUIBridge: AppUIBridge, @unchecked Sendable {
    private let handler: ActionHandler
    private let clock: @Sendable () -> Date

    init(
        handler: ActionHandler,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.handler = handler
        self.clock = clock
    }

    func launch(bundleID: String) async throws {
        _ = try await dispatch(
            "launch_app",
            ["bundle_id": .string(bundleID)]
        )
    }

    func snapshot(bundleID: String) async throws -> AccessibilitySnapshot {
        let result = try await dispatch(
            "page_source",
            [
                "bundle_id": .string(bundleID),
                "max_elements": .int(5_000),
                "max_children": .int(2_000),
            ]
        )
        guard let source = result["source"]?.stringValue else {
            throw RunnerCustomerServiceError.responseMissing("source")
        }
        guard let actual = result["bundle_id"]?.stringValue else {
            throw RunnerCustomerServiceError.responseMissing("bundle_id")
        }
        guard actual == bundleID else {
            throw RunnerCustomerServiceError.wrongForegroundApp(
                expected: bundleID,
                actual: actual
            )
        }
        return AccessibilityTreeParser.parse(source, capturedAt: clock())
    }

    func tap(x: Double, y: Double) async throws {
        _ = try await dispatch(
            "tap",
            [
                "x": .double(x),
                "y": .double(y),
                "settle": .bool(true),
                "settle_timeout": .double(2),
            ]
        )
    }

    func type(
        text: String,
        x: Double,
        y: Double,
        clear: Bool
    ) async throws {
        _ = try await dispatch(
            "type",
            [
                "x": .double(x),
                "y": .double(y),
                "text": .string(text),
                "clear": .bool(clear),
            ]
        )
    }

    func wait(seconds: Double) async throws {
        guard seconds > 0 else {
            return
        }
        try await Task<Never, Never>.sleep(
            nanoseconds: UInt64(seconds * 1_000_000_000)
        )
    }

    func now() -> Date {
        clock()
    }

    private func dispatch(
        _ method: String,
        _ params: [String: JSONValue]
    ) async throws -> [String: JSONValue] {
        let handler = handler
        return try await MainActor.run {
            let (result, error) = handler.dispatch(
                method: method,
                params: params
            )
            if let error {
                throw RunnerCustomerServiceError.rpc(error.message)
            }
            return result ?? [:]
        }
    }
}

enum RunnerLocalKeychain {
    private static let service =
        "com.openminis.ictrl.uitests.customer-service"
    private static let account = "encrypted-local-database-key"

    static func databaseKey() throws -> Data {
        if let existing = try load() {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(
                kSecRandomDefault,
                32,
                $0.baseAddress!
            )
        }
        guard randomStatus == errSecSuccess else {
            throw RunnerCustomerServiceError.rpc(
                "Unable to generate the local encryption key (\(randomStatus))"
            )
        }
        let key = Data(bytes)
        let addStatus = SecItemAdd(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: key,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary,
            nil
        )
        if addStatus == errSecDuplicateItem, let existing = try load() {
            return existing
        }
        guard addStatus == errSecSuccess else {
            throw RunnerCustomerServiceError.rpc(
                "Unable to save the local encryption key (\(addStatus))"
            )
        }
        return key
    }

    private static func load() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RunnerCustomerServiceError.rpc(
                "Unable to read the local encryption key (\(status))"
            )
        }
        return data
    }
}

actor EncryptedTakeoverStore: TakeoverStateStore {
    private let url: URL
    private let cipher: any SensitivePayloadCipher
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL, cipher: any SensitivePayloadCipher) {
        self.url = url
        self.cipher = cipher
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() async throws -> TakeoverSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TakeoverSnapshot()
        }
        let encrypted = try Data(contentsOf: url)
        let clear = try cipher.decrypt(encrypted)
        return try decoder.decode(TakeoverSnapshot.self, from: clear)
    }

    func save(_ snapshot: TakeoverSnapshot) async throws {
        let clear = try encoder.encode(snapshot)
        let encrypted = try cipher.encrypt(clear)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encrypted.write(to: url, options: .atomic)
    }
}

actor RunnerCustomerServiceRuntime {
    private let bridge: RunnerAppUIBridge
    private let queue: SQLiteTaskQueue
    private let scheduler: TaskScheduler
    private let takeover: ManualTakeoverCenter
    private let deepSeek: DeepSeekAppDriver
    private var running = false

    init(bridge: RunnerAppUIBridge) throws {
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

        let cipher = try AESGCMTaskCipher(
            keyData: RunnerLocalKeychain.databaseKey()
        )
        self.bridge = bridge
        self.queue = try SQLiteTaskQueue(
            databaseURL: base.appendingPathComponent("tasks.sqlite"),
            cipher: cipher
        )
        self.scheduler = TaskScheduler(
            queue: queue,
            workerID: "ictrl-runner"
        )
        self.takeover = ManualTakeoverCenter(
            store: EncryptedTakeoverStore(
                url: base.appendingPathComponent("takeover.enc"),
                cipher: cipher
            )
        )
        self.deepSeek = DeepSeekAppDriver(bridge: bridge)
    }

    func start() async throws -> QueueRecoveryReport {
        let recovery = try await scheduler.recoverAfterRestart()
        try await takeover.restore()
        let paused = await takeover.isAutomationPaused
        await scheduler.setAutomaticRepliesPaused(paused)
        running = true
        return recovery
    }

    func stop() {
        running = false
    }

    func enqueue(_ input: QueueTaskInput) async throws -> QueueEnqueueResult {
        try await queue.enqueue(input)
    }

    func enqueueAndProcess(
        _ input: QueueTaskInput
    ) async throws -> QueueEnqueueResult {
        let result = try await queue.enqueue(input)
        _ = try await scheduler.processAvailable(
            maximumTasks: 20,
            leaseDuration: 90,
            handler: { task in
                try await self.handle(task)
            }
        )
        return result
    }

    func processNext() async throws -> TaskSchedulerResult {
        try await scheduler.processNext(
            leaseDuration: 90,
            handler: { task in
                try await self.handle(task)
            }
        )
    }

    func setAutomaticRepliesPaused(_ paused: Bool) async throws {
        if paused {
            try await takeover.pauseAllAutomaticReplies()
        } else {
            try await takeover.resumeAutomaticReplies()
        }
        await scheduler.setAutomaticRepliesPaused(paused)
    }

    func pendingHumanTasks() async -> [TakeoverTask] {
        await takeover.pendingTasks()
    }

    private func handle(_ task: QueuedTask) async throws -> [TaskEvent] {
        guard running else {
            return [.escalateToHuman]
        }

        let assessment = MerchantPolicy.assess(
            task.payload.buyerQuestion
        )
        if assessment.requiresHumanReview
            || assessment.category == .platformNotice
            || assessment.category == .emptyMessage {
            let reason = assessment.reasons.joined(separator: "; ")
            await submitTakeoverTask(
                task,
                assessment: assessment,
                reason: reason.isEmpty
                    ? "Message requires human verification"
                    : reason
            )
            return [.startProcessing, .escalateToHuman]
        }

        let conversation = ConversationContext(
            platform: task.platform,
            storeName: task.storeName,
            customerName: task.payload.customerName,
            messages: task.payload.conversation.map {
                ChatMessage(
                    side: $0.side,
                    text: $0.text,
                    observedAt: $0.observedAt
                )
            }
        )

        let generated: String
        if !task.payload.suggestedReply
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            generated = task.payload.suggestedReply
        } else if let local = MerchantPolicy.deterministicReply(
            for: task.payload.buyerQuestion
        ) {
            generated = local
        } else {
            let turn = try await deepSeek.runCustomerTurn(
                prompt: DeepSeekPromptBuilder.prompt(for: conversation)
            )
            guard turn.success else {
                await submitTakeoverTask(
                    task,
                    assessment: assessment,
                    reason: turn.failureReason
                        ?? "DeepSeek App did not produce a reply"
                )
                return [.startProcessing, .escalateToHuman]
            }
            generated = turn.answer
        }

        let quality = ReplyQualityGate.validate(
            generated,
            assessment: assessment
        )
        guard quality.canAutoSend else {
            await submitTakeoverTask(
                task,
                assessment: assessment,
                reason: "Reply quality gate: "
                    + quality.violations
                        .map(\.rawValue)
                        .joined(separator: ", ")
            )
            return [.startProcessing, .escalateToHuman]
        }

        let receipt = try await send(
            quality.normalizedReply,
            platform: task.platform
        )
        switch receipt {
        case .sentVerified:
            return [
                .startProcessing,
                .generateReply,
                .requestSend,
                .sendVerified,
            ]
        case let .sendUncertain(reason):
            await submitTakeoverTask(
                task,
                assessment: assessment,
                reason: "Send result is uncertain: \(reason)"
            )
            return [
                .startProcessing,
                .generateReply,
                .requestSend,
                .sendNotVerified,
            ]
        }
    }

    private func send(
        _ reply: String,
        platform: CommercePlatform
    ) async throws -> RunnerSendReceipt {
        switch platform {
        case .pinduoduo:
            try await bridge.launch(bundleID: PinduoduoDriver.bundleID)
            let driver = PinduoduoDriver(bridge: bridge)
            guard case .directChat = try await driver.inspect() else {
                throw RunnerCustomerServiceError.unsupportedSurface
            }
            try await driver.prepareReply(reply)
            switch try await driver.sendPreparedReply(reply) {
            case .sentVerified:
                return .sentVerified
            case let .sendUncertain(reason):
                return .sendUncertain(reason: reason)
            }
        case .qianniu:
            try await bridge.launch(bundleID: QianniuDriver.bundleID)
            let driver = QianniuDriver(bridge: bridge)
            guard case .directChat = try await driver.inspect() else {
                throw RunnerCustomerServiceError.unsupportedSurface
            }
            try await driver.prepareReply(reply)
            switch try await driver.sendPreparedReply(reply) {
            case .sentVerified:
                return .sentVerified
            case let .sendUncertain(reason):
                return .sendUncertain(reason: reason)
            }
        }
    }

    private func submitTakeoverTask(
        _ task: QueuedTask,
        assessment: RiskAssessment,
        reason: String
    ) async {
        let source: TakeoverSource
        switch task.platform {
        case .pinduoduo:
            source = .pinduoduo
        case .qianniu:
            source = .qianniu
        }
        let humanTask = TakeoverTask(
            source: source,
            storeName: task.storeName,
            buyerName: task.payload.customerName,
            buyerQuestion: task.payload.buyerQuestion,
            originalConversation: task.payload.conversation.map {
                ChatMessage(
                    side: $0.side,
                    text: $0.text,
                    observedAt: $0.observedAt
                )
            },
            orderInfo: task.payload.orderInfo.map {
                TakeoverOrderInfo(
                    orderID: $0.orderID,
                    status: $0.status,
                    carrier: $0.carrier,
                    trackingNumber: $0.trackingNumber
                )
            },
            aiReason: reason,
            aiSuggestedReply: assessment.safeHoldingReply
                ?? task.payload.suggestedReply,
            isHighRisk: assessment.requiresHumanReview,
            priority: assessment.requiresHumanReview ? .high : .normal,
            createdAt: Date()
        )
        do {
            let submission = try await takeover.submit(humanTask)
            try await postLocalNotification(submission.notification)
        } catch {
            iCTRLUITests.logBuffer.append(
                "Customer-service manual task could not be saved: "
                    + String(describing: error)
            )
        }
    }

    private func postLocalNotification(
        _ request: TakeoverNotificationRequest
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        let notification = UNNotificationRequest(
            identifier: "customer-service-\(request.taskID.uuidString)",
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(notification)
    }
}

private enum RunnerSendReceipt {
    case sentVerified
    case sendUncertain(reason: String)
}
