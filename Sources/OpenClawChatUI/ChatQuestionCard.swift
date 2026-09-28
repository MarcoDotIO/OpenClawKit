import Foundation
import Observation
import OpenClawKit

// Ported from upstream OpenClaw 2026.9.6 `ChatQuestionCard.swift` (card model and view-model integration).
// The SwiftUI question card views belong with the transcript views.

/// Presentation status of an `ask_user` question card.
public enum OpenClawQuestionCardStatus: Sendable, Equatable {
    /// Waiting for an answer.
    case pending
    /// An answer is being submitted.
    case submitting
    /// Answered from this client.
    case answered
    /// Answered from another client.
    case answeredElsewhere
    /// Expired.
    case expired
    /// Cancelled (skipped).
    case cancelled
    /// The outcome can no longer be recovered.
    case unavailable
}

/// Observable state of one `ask_user` question card, including local answer drafts.
@MainActor
@Observable
public final class OpenClawQuestionCardModel: Identifiable {
    /// Question identifier.
    public let id: String
    /// Latest question record.
    public private(set) var record: QuestionRecord {
        didSet { self.discardTerminalDrafts() }
    }

    /// Whether an answer submission is in flight.
    public private(set) var isSubmitting = false
    /// Whether a skip is in flight.
    public private(set) var isSkipping = false
    /// Whether this client answered the question.
    public private(set) var wasAnsweredLocally = false
    /// Submission error.
    public private(set) var errorText: String?
    /// Selected option labels keyed by question.
    public private(set) var selectedOptions: [String: Set<String>] = [:]
    /// Free-text (or secret) drafts keyed by question.
    public private(set) var otherText: [String: String] = [:]
    /// Whether the local expiry timer fired.
    public private(set) var isLocallyExpired = false {
        didSet { self.discardTerminalDrafts() }
    }

    /// Whether the terminal outcome is no longer recoverable.
    public private(set) var isRecoveryUnavailable = false {
        didSet { self.discardTerminalDrafts() }
    }

    private var allowedHostsDraft: String?

    /// Creates a card for a question record.
    public init(record: QuestionRecord) {
        self.id = record.id
        self.record = record
    }

    /// Applies a newer record; returns whether anything changed. Terminal cards never return to pending.
    @discardableResult
    public func apply(record: QuestionRecord) -> Bool {
        let nextRecord = self.preservingKnownAnswers(in: record)
        guard record.id == self.id,
              !((self.record.status != .pending || self.isRecoveryUnavailable) && record.status == .pending),
              !Self.recordsMatch(self.record, nextRecord)
        else { return false }
        self.record = nextRecord
        self.isSubmitting = self.isSubmitting && nextRecord.status == .pending
        self.isSkipping = self.isSkipping && nextRecord.status == .pending
        self.isLocallyExpired = false
        self.isRecoveryUnavailable = false
        return true
    }

    private func preservingKnownAnswers(in record: QuestionRecord) -> QuestionRecord {
        guard record.status == .answered, record.answers == nil, let answers = self.record.answers else {
            return record
        }
        return QuestionRecord(
            id: record.id,
            questions: record.questions,
            agentid: record.agentid,
            sessionkey: record.sessionkey,
            runid: record.runid,
            createdatms: record.createdatms,
            expiresatms: record.expiresatms,
            status: record.status,
            answers: answers,
            resolvedby: record.resolvedby)
    }

    /// Presentation status at `date`.
    public func status(at date: Date = Date()) -> OpenClawQuestionCardStatus {
        if self.isRecoveryUnavailable { return .unavailable }
        switch self.record.status {
        case .answered:
            return self.wasAnsweredLocally ? .answered : .answeredElsewhere
        case .cancelled:
            return .cancelled
        case .expired:
            return .expired
        case .pending:
            if self.isLocallyExpired || date.timeIntervalSince1970 * 1000 >= Double(self.record.expiresatms) {
                return .expired
            }
            return self.isSubmitting ? .submitting : .pending
        }
    }

    /// Seconds until expiry at `date`.
    public func remainingSeconds(at date: Date = Date()) -> Int {
        max(0, Int(ceil(Double(self.record.expiresatms) / 1000 - date.timeIntervalSince1970)))
    }

    /// Toggles an option (single-select questions replace the selection and clear free text).
    public func toggleOption(questionID: String, label: String) {
        guard let question = self.record.questions.first(where: { $0.questionid == questionID }),
              question.options.contains(where: { $0.label == label }),
              self.status() == .pending
        else { return }
        var selected = self.selectedOptions[questionID] ?? []
        if question.multiselect == true {
            if selected.contains(label) {
                selected.remove(label)
            } else {
                selected.insert(label)
            }
        } else {
            selected = selected == [label] ? [] : [label]
            if !selected.isEmpty {
                self.otherText[questionID] = ""
            }
        }
        self.selectedOptions[questionID] = selected
        self.errorText = nil
    }

    /// Toggles option `1...4` by number; returns whether the option exists.
    @discardableResult
    public func toggleOption(questionID: String, optionNumber: Int) -> Bool {
        guard let question = self.record.questions.first(where: { $0.questionid == questionID }),
              self.status() == .pending,
              (1...4).contains(optionNumber),
              question.options.indices.contains(optionNumber - 1)
        else { return false }
        self.toggleOption(questionID: questionID, label: question.options[optionNumber - 1].label)
        return true
    }

    /// Updates the free-text answer (single-select questions clear their option selection).
    public func setOtherText(questionID: String, value: String) {
        guard let question = self.record.questions.first(where: { $0.questionid == questionID }),
              question.options.isEmpty || question.isother == true,
              self.status() == .pending
        else { return }
        self.otherText[questionID] = value
        let hasText = question.issecret == true ? !value.isEmpty : !value
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if question.multiselect != true, hasText {
            self.selectedOptions[questionID] = []
        }
        self.errorText = nil
    }

    /// Editable allowed-hosts text for secret-store questions.
    public var secretStoreAllowedHostsText: String {
        get {
            self.allowedHostsDraft ?? self.record.questions.first?.secretstore?.allowedhosts?
                .joined(separator: ", ") ?? ""
        }
        set {
            guard self.status() == .pending else { return }
            self.allowedHostsDraft = newValue
            self.errorText = nil
        }
    }

    /// Allowed HTTPS hosts sent with a protected-secret answer.
    public var secretStoreAllowedHosts: [String]? {
        guard self.record.questions.first?.secretstore?.kind.stringValue == "secret" else { return nil }
        return self.secretStoreAllowedHostsText.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    private func discardTerminalDrafts() {
        guard self.record.status != .pending || self.isLocallyExpired || self.isRecoveryUnavailable else { return }
        // Every terminal producer, including remote recovery and the expiry timer, retires raw input here.
        self.otherText.removeAll()
        self.selectedOptions.removeAll()
        self.allowedHostsDraft = nil
    }

    /// Whether every question has an answer and the card is pending.
    public var canSubmit: Bool {
        self.status() == .pending && self.answers() != nil
    }

    /// Starts a submission and returns the answers, or `nil` when the card cannot submit.
    public func beginSubmission() -> [String: [String]]? {
        guard let answers = self.answers(), self.status() == .pending else { return nil }
        self.isSubmitting = true
        self.isSkipping = false
        self.errorText = nil
        return answers
    }

    /// Starts a skip; returns whether the card was pending.
    public func beginSkip() -> Bool {
        guard self.status() == .pending else { return false }
        self.isSubmitting = true
        self.isSkipping = true
        self.errorText = nil
        return true
    }

    /// Records a local answer with the gateway-normalized answers.
    public func markAnsweredLocally(answers: QuestionAnswers) {
        self.wasAnsweredLocally = true
        self.apply(resolved: .init(id: self.id, status: .answered, answers: answers))
    }

    /// Records a local skip.
    public func markSkippedLocally() {
        self.apply(resolved: .init(id: self.id, status: .cancelled))
    }

    /// Records an answer from another client.
    public func markAnsweredElsewhere() {
        self.apply(resolved: .init(id: self.id, status: .answered))
    }

    /// Marks the outcome unrecoverable; returns whether the state changed.
    @discardableResult
    public func markRecoveryUnavailable() -> Bool {
        guard !self.isRecoveryUnavailable else { return false }
        self.isSubmitting = false
        self.isSkipping = false
        self.isLocallyExpired = false
        self.isRecoveryUnavailable = true
        return true
    }

    /// Applies a `question.resolved` event.
    public func apply(resolved: OpenClawQuestionResolvedEvent) {
        guard resolved.id == self.id else { return }
        self.isSubmitting = false
        self.isSkipping = false
        self.isLocallyExpired = false
        self.isRecoveryUnavailable = false
        self.record = QuestionRecord(
            id: self.record.id,
            questions: self.record.questions,
            agentid: self.record.agentid,
            sessionkey: self.record.sessionkey,
            runid: self.record.runid,
            createdatms: self.record.createdatms,
            expiresatms: self.record.expiresatms,
            status: resolved.status,
            answers: resolved.answers ?? self.record.answers,
            resolvedby: self.record.resolvedby)
    }

    /// Ends a failed submission; secret drafts are discarded unless `preserveSecretDraft`.
    public func failSubmission(_ message: String, preserveSecretDraft: Bool = false) {
        if !preserveSecretDraft {
            for question in self.record.questions where question.issecret == true {
                self.otherText.removeValue(forKey: question.questionid)
            }
        }
        self.isSubmitting = false
        self.isSkipping = false
        self.errorText = message
    }

    func observeLocalExpiry(at date: Date) -> Bool {
        guard self.record.status == .pending, !self.isLocallyExpired,
              date.timeIntervalSince1970 * 1000 >= Double(self.record.expiresatms)
        else { return false }
        self.isLocallyExpired = true
        self.isSubmitting = false
        self.isSkipping = false
        return true
    }

    func localExpiryDelay(at date: Date) -> TimeInterval? {
        guard self.record.status == .pending, !self.isLocallyExpired else { return nil }
        return max(0, Double(self.record.expiresatms) / 1000 - date.timeIntervalSince1970)
    }

    /// One-line terminal summary for a question (secret answers are never echoed).
    public func terminalSummaryText(for question: Question) -> String {
        // Secret questions never echo answer text into the persisted timeline;
        // the record only carries a synthetic marker, but masking here keeps the
        // summary honest for every secret producer, not just store-bound ones.
        let echoedAnswers = question.issecret == true
            ? nil
            : self.answerValues(questionID: question.questionid)?.joined(separator: ", ")
        return switch self.status() {
        case .answered:
            echoedAnswers ?? String(localized: "Answered")
        case .answeredElsewhere:
            echoedAnswers
                ?? String(localized: "Answered elsewhere")
        case .cancelled:
            String(localized: "Skipped")
        case .expired:
            String(localized: "Expired")
        case .unavailable:
            String(localized: "Unavailable")
        case .pending, .submitting:
            String(localized: "Pending")
        }
    }

    private func answers() -> [String: [String]]? {
        var result: [String: [String]] = [:]
        for question in self.record.questions {
            let selected = self.selectedOptions[question.questionid] ?? []
            var values = question.options.compactMap { selected.contains($0.label) ? $0.label : nil }
            let draft = self.otherText[question.questionid]
            let other = question.issecret == true ? draft : draft?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let other, !other.isEmpty {
                values.append(other)
            }
            guard !values.isEmpty else { return nil }
            result[question.questionid] = values
        }
        return result
    }

    private func answerValues(questionID: String) -> [String]? {
        guard let answer = self.record.answers?.answers[questionID],
              let values = answer.arrayValue?.compactMap(\.stringValue),
              !values.isEmpty
        else { return nil }
        return values
    }

    private static func recordsMatch(_ lhs: QuestionRecord, _ rhs: QuestionRecord) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
}

private enum QuestionLookupResult {
    case record(QuestionRecord)
    case notFound
    case failed
}

private struct QuestionRefreshApplyResult {
    let complete: Bool
    let changed: Bool
}

extension OpenClawChatViewModel {
    /// Retained attachment controls may outlive a Gateway account, but its questions cannot.
    public func retireQuestionAuthority() {
        guard !self.isQuestionAuthorityRetired else { return }
        self.isQuestionAuthorityRetired = true
        self.questionRefreshGeneration &+= 1
        self.questionStateRevision &+= 1
        self.questionRefreshRetryTask?.cancel()
        self.questionRefreshRetryTask = nil
        for task in self.questionExpiryTasks.values {
            task.cancel()
        }
        self.questionExpiryTasks.removeAll()
        self.questionExpiryDeadlines.removeAll()
        for card in self.questionCards {
            card.markRecoveryUnavailable()
        }
        self.questionCards.removeAll()
        self.markTimelineChanged()
    }

    /// Question cards that belong to the visible session.
    public var visibleQuestionCards: [OpenClawQuestionCardModel] {
        self.questionCards.filter { card in
            guard let key = card.record.sessionkey else { return true }
            return self.matchesCurrentSessionKey(
                incoming: key,
                agentId: card.record.agentid,
                current: self.sessionKey)
        }
    }

    func refreshQuestions() async {
        guard !self.isQuestionAuthorityRetired else { return }
        self.questionRefreshGeneration &+= 1
        let refreshGeneration = self.questionRefreshGeneration
        self.questionRefreshRetryTask?.cancel()
        self.questionRefreshRetryTask = nil
        await self.refreshQuestions(generation: refreshGeneration, retryIndex: 0)
    }

    private func refreshQuestions(generation refreshGeneration: UInt64, retryIndex: Int) async {
        guard refreshGeneration == self.questionRefreshGeneration else { return }
        let stateRevision = self.questionStateRevision
        // Released 2026.7.x gateways predate question.list and reject it with
        // "missing scope: operator.admin" (authorization runs before dispatch),
        // so an unadvertised method must resolve as unavailable without a call.
        if await self.transport.gatewayAdvertisesMethod("question.list") == false {
            guard self.questionRefreshSnapshotIsCurrent(
                generation: refreshGeneration,
                stateRevision: stateRevision)
            else { return }
            self.clearPendingQuestionsForUnavailableList()
            return
        }
        do {
            let records = try await self.transport.listQuestions()
            guard self.questionRefreshSnapshotIsCurrent(
                generation: refreshGeneration,
                stateRevision: stateRevision)
            else { return }
            let listedIDs = Set(records.map(\.id))
            let missingPending = self.questionCards.filter { model in
                model.record.status == .pending &&
                    !model.isRecoveryUnavailable &&
                    !listedIDs.contains(model.id)
            }
            let lookups = await self.fetchMissingQuestionLookups(missingPending)
            guard self.questionRefreshSnapshotIsCurrent(
                generation: refreshGeneration,
                stateRevision: stateRevision)
            else { return }
            let result = self.applyQuestionRefresh(records: records, lookups: lookups)
            if result.complete {
                self.questionRefreshRetryTask = nil
            } else {
                self.scheduleQuestionRefreshRetry(
                    generation: refreshGeneration,
                    retryIndex: result.changed ? 0 : retryIndex)
            }
        } catch let error as GatewayResponseError where Self.questionListIsUnavailable(error) {
            guard self.questionRefreshSnapshotIsCurrent(
                generation: refreshGeneration,
                stateRevision: stateRevision)
            else { return }
            self.clearPendingQuestionsForUnavailableList()
        } catch {
            guard self.questionRefreshSnapshotIsCurrent(
                generation: refreshGeneration,
                stateRevision: stateRevision)
            else { return }
            self.scheduleQuestionRefreshRetry(
                generation: refreshGeneration,
                retryIndex: retryIndex)
        }
    }

    private func fetchMissingQuestionLookups(
        _ models: [OpenClawQuestionCardModel]) async
        -> [(OpenClawQuestionCardModel, QuestionLookupResult)]
    {
        // The gateway enumerates pending questions only; terminal records remain addressable
        // briefly by known ID. Cards observed by this view model persist without timed eviction,
        // but session transcripts do not contain enough question data to recreate them on launch.
        var lookups: [(OpenClawQuestionCardModel, QuestionLookupResult)] = []
        for model in models {
            do {
                let record = try await self.transport.getQuestion(id: model.id)
                lookups.append((model, .record(record)))
            } catch let error as GatewayResponseError where Self.questionIsNotFound(error) {
                lookups.append((model, .notFound))
            } catch {
                lookups.append((model, .failed))
            }
        }
        return lookups
    }

    private func applyQuestionRefresh(
        records: [QuestionRecord],
        lookups: [(OpenClawQuestionCardModel, QuestionLookupResult)]) -> QuestionRefreshApplyResult
    {
        var changed = false
        for record in records {
            if let model = self.questionCards.first(where: { $0.id == record.id }) {
                changed = model.apply(record: record) || changed
            } else {
                self.questionCards.append(OpenClawQuestionCardModel(record: record))
                changed = true
            }
        }
        var complete = true
        for (model, result) in lookups {
            guard self.questionCards.contains(where: { $0 === model }) else { continue }
            switch result {
            case let .record(record):
                changed = model.apply(record: record) || changed
            case .notFound:
                // The terminal tombstone has aged out, so the question is no longer actionable,
                // but its answered/cancelled/expired outcome cannot be reconstructed.
                changed = model.markRecoveryUnavailable() || changed
            case .failed:
                complete = false
            }
        }
        self.syncQuestionExpirations()
        if changed {
            self.questionStateRevision &+= 1
            self.markTimelineChanged()
        }
        return QuestionRefreshApplyResult(complete: complete, changed: changed)
    }

    private func clearPendingQuestionsForUnavailableList() {
        let previousCount = self.questionCards.count
        self.questionCards.removeAll {
            let status = $0.status()
            guard status == .pending || status == .submitting else { return false }
            $0.markRecoveryUnavailable()
            return true
        }
        self.syncQuestionExpirations()
        if self.questionCards.count != previousCount {
            self.questionStateRevision &+= 1
            self.markTimelineChanged()
        }
    }

    private func questionRefreshSnapshotIsCurrent(generation: UInt64, stateRevision: UInt64) -> Bool {
        guard !self.isQuestionAuthorityRetired else { return false }
        guard generation == self.questionRefreshGeneration else { return false }
        guard stateRevision == self.questionStateRevision else {
            self.restartQuestionRefreshAfterStateChange(generation: generation)
            return false
        }
        return true
    }

    nonisolated private static func questionListIsUnavailable(_ error: GatewayResponseError) -> Bool {
        if ChatGatewayErrorFacts.missingScope(error) == "operator.questions" { return true }
        return error.code == "INVALID_REQUEST" && error.message == "unknown method: question.list"
    }

    nonisolated private static func questionIsNotFound(_ error: GatewayResponseError) -> Bool {
        ChatGatewayErrorFacts.reason(error) == "QUESTION_NOT_FOUND"
    }

    private func restartQuestionRefreshAfterStateChange(generation: UInt64) {
        // Local question mutations invalidate the whole lookup snapshot, not one transport attempt.
        // Restart the bounded budget so a late mutation cannot consume the last reconciliation slot.
        self.scheduleQuestionRefreshRetry(generation: generation, retryIndex: 0)
    }

    private func scheduleQuestionRefreshRetry(generation: UInt64, retryIndex: Int) {
        guard !self.isQuestionAuthorityRetired, generation == self.questionRefreshGeneration else { return }
        guard self.questionRefreshRetryDelaysMs.indices.contains(retryIndex) else {
            self.questionRefreshRetryTask = nil
            return
        }
        let delayMs = self.questionRefreshRetryDelaysMs[retryIndex]
        let stateRevision = self.questionStateRevision
        self.questionRefreshRetryTask?.cancel()
        self.questionRefreshRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, let self,
                  generation == self.questionRefreshGeneration
            else { return }
            // A mutation during backoff invalidates the reconciliation attempt, not the retry budget.
            let nextRetryIndex = stateRevision == self.questionStateRevision ? retryIndex + 1 : 0
            await self.refreshQuestions(generation: generation, retryIndex: nextRetryIndex)
        }
    }

    func upsertQuestion(_ record: QuestionRecord) {
        guard !self.isQuestionAuthorityRetired else { return }
        if let model = self.questionCards.first(where: { $0.id == record.id }) {
            guard model.apply(record: record) else { return }
        } else {
            self.questionCards.append(OpenClawQuestionCardModel(record: record))
        }
        self.questionStateRevision &+= 1
        self.syncQuestionExpirations()
        self.markTimelineChanged()
    }

    func resolveQuestionEvent(_ event: OpenClawQuestionResolvedEvent) {
        guard !self.isQuestionAuthorityRetired else { return }
        self.questionCards.first(where: { $0.id == event.id })?.apply(resolved: event)
        self.questionStateRevision &+= 1
        self.syncQuestionExpirations()
        self.markTimelineChanged()
    }

    func reconcileQuestionsAfterEvent() {
        guard !self.isQuestionAuthorityRetired else { return }
        // Invalidate a list snapshot captured before this event, then fetch the
        // authoritative set so other pending cards from that snapshot are not lost.
        self.questionRefreshGeneration &+= 1
        self.questionRefreshRetryTask?.cancel()
        self.questionRefreshRetryTask = nil
        Task { [weak self] in await self?.refreshQuestions() }
    }

    /// Submits a question card's answers.
    public func submitQuestion(_ model: OpenClawQuestionCardModel) async {
        guard !self.isQuestionAuthorityRetired,
              self.questionCards.contains(where: { $0 === model }),
              let answers = model.beginSubmission()
        else { return }
        self.questionStateRevision &+= 1
        do {
            let resolvedAnswers = try await self.transport.resolveQuestion(
                id: model.id,
                answers: answers,
                secretStoreAllowedHosts: model.secretStoreAllowedHosts)
            guard !self.isQuestionAuthorityRetired else { return }
            // Only Gateway-normalized answers may outlive the request, including stored-secret markers.
            model.markAnsweredLocally(answers: resolvedAnswers)
            self.questionStateRevision &+= 1
            self.syncQuestionExpirations()
            self.markTimelineChanged()
        } catch {
            guard !self.isQuestionAuthorityRetired else { return }
            let responseError = error as? GatewayResponseError
            let preserveSecretDraft = responseError.map { responseError in
                responseError.code == "INVALID_REQUEST" &&
                    ChatGatewayErrorFacts.reason(responseError) == nil &&
                    !ChatGatewayErrorFacts.isAuthorizationFailure(responseError)
            } ?? false
            model.failSubmission(error.localizedDescription, preserveSecretDraft: preserveSecretDraft)
            self.questionStateRevision &+= 1
        }
    }

    /// Skips (cancels) a question card.
    public func skipQuestion(_ model: OpenClawQuestionCardModel) async {
        guard !self.isQuestionAuthorityRetired,
              self.questionCards.contains(where: { $0 === model }),
              model.beginSkip()
        else { return }
        self.questionStateRevision &+= 1
        do {
            try await self.transport.cancelQuestion(id: model.id)
            guard !self.isQuestionAuthorityRetired else { return }
            model.markSkippedLocally()
            self.questionStateRevision &+= 1
            self.syncQuestionExpirations()
            self.markTimelineChanged()
        } catch {
            guard !self.isQuestionAuthorityRetired else { return }
            model.failSubmission(error.localizedDescription)
            self.questionStateRevision &+= 1
        }
    }

    func expireQuestionIfNeeded(
        _ model: OpenClawQuestionCardModel,
        at date: Date = Date())
    {
        guard !self.isQuestionAuthorityRetired,
              self.questionCards.first(where: { $0.id == model.id }) === model
        else { return }
        if model.observeLocalExpiry(at: date) {
            self.questionStateRevision &+= 1
            self.syncQuestionExpirations(at: date)
            self.markTimelineChanged()
            Task { [weak self] in await self?.refreshQuestions() }
        } else {
            self.syncQuestionExpirations(at: date)
        }
    }

    private func syncQuestionExpirations(at date: Date = Date()) {
        let modelsByID = Dictionary(uniqueKeysWithValues: self.questionCards.map { ($0.id, $0) })
        let cancelledIDs = self.questionExpiryTasks.keys.filter { modelsByID[$0] == nil }
        for id in cancelledIDs {
            self.questionExpiryTasks.removeValue(forKey: id)?.cancel()
            self.questionExpiryDeadlines.removeValue(forKey: id)
        }
        for model in self.questionCards {
            guard let delay = model.localExpiryDelay(at: date) else {
                self.questionExpiryTasks.removeValue(forKey: model.id)?.cancel()
                self.questionExpiryDeadlines.removeValue(forKey: model.id)
                continue
            }
            let deadline = date.addingTimeInterval(delay)
            if let scheduled = self.questionExpiryDeadlines[model.id],
               abs(scheduled.timeIntervalSince(deadline)) < 0.01
            {
                continue
            }
            self.questionExpiryTasks.removeValue(forKey: model.id)?.cancel()
            self.questionExpiryDeadlines[model.id] = deadline
            self.questionExpiryTasks[model.id] = Task { [weak self, weak model] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, let model else { return }
                self.questionExpiryTasks.removeValue(forKey: model.id)
                self.questionExpiryDeadlines.removeValue(forKey: model.id)
                self.expireQuestionIfNeeded(model)
            }
        }
    }
}
