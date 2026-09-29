// ChatUI views ship on iOS, macOS and visionOS. tvOS and watchOS get only the non-UI chat core
// (view model, transport, models, parsers), because these views rely on APIs such as TextEditor,
// textSelection and PhotosPicker that are unavailable there.
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import OpenClawKit
import SwiftUI

// Ported from upstream OpenClaw 2026.9.6 `ChatQuestionCard.swift` (card views). The card model and the
// view-model question plumbing live in ChatQuestionCard.swift.
struct OpenClawQuestionCard: View {
    @Bindable private var model: OpenClawQuestionCardModel
    private let onSubmit: @MainActor @Sendable (OpenClawQuestionCardModel) async -> Void
    private let onSkip: (@MainActor @Sendable (OpenClawQuestionCardModel) async -> Void)?
    #if os(macOS)
    @FocusState private var focusedQuestionID: String?
    #endif

    init(
        model: OpenClawQuestionCardModel,
        onSubmit: @escaping @MainActor @Sendable (OpenClawQuestionCardModel) async -> Void,
        onSkip: @escaping @MainActor @Sendable (OpenClawQuestionCardModel) async -> Void)
    {
        self.model = model
        self.onSubmit = onSubmit
        self.onSkip = onSkip
    }

    var body: some View {
        let status = self.model.status()
        if status == .pending || status == .submitting {
            self.pendingCard
        } else {
            self.terminalSummary
        }
    }

    private var pendingCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                ForEach(self.model.record.questions, id: \.questionid) { question in
                    self.questionSection(question, now: context.date)
                }
                self.footer(now: context.date)
            }
            .padding(16)
            .background(OpenClawChatTheme.subtleCard, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.secondary.opacity(0.2)))
        }
    }

    private var terminalSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(self.model.record.questions, id: \.questionid) { question in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: "\(question.header):")
                        .font(OpenClawChatTypography.body(size: 14, weight: .semibold, relativeTo: .callout))
                    Text(self.model.terminalSummaryText(for: question))
                        .font(OpenClawChatTypography.body(size: 14, weight: .regular, relativeTo: .callout))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(OpenClawChatTheme.subtleCard, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question summary")
    }

    private func questionSection(_ question: Question, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.header.uppercased())
                .font(OpenClawChatTypography.captionSemiBold)
                .foregroundStyle(OpenClawChatTheme.accent)
            Text(question.question)
                .font(OpenClawChatTypography.body)
            if let store = question.secretstore {
                self.secretStoreConsent(question: question, store: store, now: now)
            }
            ForEach(question.options, id: \.label) { option in
                self.optionRow(question: question, option: option, now: now)
            }
            if question.options.isEmpty || question.isother == true {
                if question.issecret == true {
                    // Secret answers must never render on screen: masked entry, no
                    // autocorrect/prediction capture, same submit path as free text.
                    SecureField(
                        text: Binding(
                            get: { self.model.otherText[question.questionid] ?? "" },
                            set: { self.model.setOtherText(questionID: question.questionid, value: $0) }))
                    {
                        Text("Secret value").font(OpenClawChatTypography.body)
                    }
                    .font(OpenClawChatTypography.body)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disabled(self.model.status(at: now) != .pending)
                    .accessibilityLabel("Secret value")
                } else {
                    TextField(
                        "Other answer",
                        text: Binding(
                            get: { self.model.otherText[question.questionid] ?? "" },
                            set: { self.model.setOtherText(questionID: question.questionid, value: $0) }),
                        axis: .vertical)
                        .font(OpenClawChatTypography.body)
                        .textFieldStyle(.roundedBorder)
                        .disabled(self.model.status(at: now) != .pending)
                        .accessibilityLabel("Other answer")
                }
            }
        }
        #if os(macOS)
        .focusable()
            .focused(self.$focusedQuestionID, equals: question.questionid)
            .onKeyPress(characters: .decimalDigits) { keyPress in
                guard self.focusedQuestionID == question.questionid else { return .ignored }
                return self.handleNumberKey(keyPress, question: question, now: now)
            }
            .onKeyPress(.return) {
                guard self.focusedQuestionID == question.questionid,
                      self.model.status(at: now) == .pending,
                      self.model.canSubmit
                else { return .ignored }
                Task { await self.onSubmit(self.model) }
                return .handled
            }
        #endif
    }

    private func secretStoreConsent(
        question: Question,
        store: QuestionSecretStoreBinding,
        now: Date) -> some View
    {
        let protectedSecret = store.kind.stringValue == "secret"
        let agent = self.model.record.agentid ?? String(localized: "Unknown")
        let session = self.model.record.sessionkey ?? String(localized: "Unknown")
        let kind = protectedSecret ? String(localized: "Protected secret") :
            String(localized: "Agent-readable environment")
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(format: String(localized: "Requested by %@ • %@"), agent, session))
                .font(OpenClawChatTypography.caption)
                .foregroundStyle(.secondary)
            Text(String(format: String(localized: "Stores %@ as %@"), store.name, kind))
                .font(OpenClawChatTypography.body)
            if let reason = store.reason, !reason.isEmpty {
                Text(reason).font(OpenClawChatTypography.body)
            }
            if let existing = question.secretstoreexisting {
                let updated = Date(timeIntervalSince1970: Double(existing.updatedatms) / 1000)
                    .formatted(date: .abbreviated, time: .shortened)
                Text(String(format: String(localized: "Replaces %@ — last updated %@"), store.name, updated))
                    .font(OpenClawChatTypography.captionSemiBold)
                    .foregroundStyle(OpenClawChatTheme.danger)
                if let updatedBy = existing.updatedby {
                    Text(String(format: String(localized: "Updated by %@"), updatedBy))
                        .font(OpenClawChatTypography.caption)
                }
            }
            if protectedSecret {
                Text("Allowed HTTPS hosts").font(OpenClawChatTypography.captionSemiBold)
                TextField(text: self.$model.secretStoreAllowedHostsText, axis: .vertical) {
                    Text("api.example.com, uploads.example.com").font(OpenClawChatTypography.body)
                }
                .font(OpenClawChatTypography.body)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
                .disabled(self.model.status(at: now) != .pending)
                .accessibilityLabel("Allowed HTTPS hosts")
                Text("Exact HTTPS hosts, separated by commas or spaces. Empty allows config SecretRefs only.")
                    .font(OpenClawChatTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func optionRow(question: Question, option: QuestionOption, now: Date) -> some View {
        let selected = self.model.selectedOptions[question.questionid]?.contains(option.label) == true
        return Button {
            #if os(macOS)
            self.focusedQuestionID = question.questionid
            #endif
            self.model.toggleOption(questionID: question.questionid, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected
                    ? (question.multiselect == true ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (question.multiselect == true ? "square" : "circle"))
                    .foregroundStyle(selected ? OpenClawChatTheme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(OpenClawChatTypography.body)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(OpenClawChatTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(self.model.status(at: now) != .pending)
        .accessibilityLabel(option.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private func footer(now: Date) -> some View {
        let status = self.model.status(at: now)
        if status == .pending || status == .submitting {
            HStack {
                Text(self.countdownText(now: now))
                    .font(OpenClawChatTypography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let onSkip = self.onSkip {
                    Button {
                        Task { await onSkip(self.model) }
                    } label: {
                        if self.model.isSkipping {
                            Text("Skipping…")
                                .font(OpenClawChatTypography.body(size: 14, weight: .semibold, relativeTo: .callout))
                        } else {
                            Text("Skip")
                                .font(OpenClawChatTypography.body(size: 14, weight: .semibold, relativeTo: .callout))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(status == .submitting)
                }
                Button {
                    Task { await self.onSubmit(self.model) }
                } label: {
                    if status == .submitting, !self.model.isSkipping {
                        Text("Submitting…")
                            .font(OpenClawChatTypography.body(size: 14, weight: .semibold, relativeTo: .callout))
                    } else {
                        Text("Submit")
                            .font(OpenClawChatTypography.body(size: 14, weight: .semibold, relativeTo: .callout))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!self.model.canSubmit || status == .submitting)
            }
            if let errorText = self.model.errorText {
                Text(errorText)
                    .font(OpenClawChatTypography.caption)
                    .foregroundStyle(OpenClawChatTheme.danger)
            }
        }
    }

    private func countdownText(now: Date) -> String {
        let seconds = self.model.remainingSeconds(at: now)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    #if os(macOS)
    private func handleNumberKey(
        _ keyPress: KeyPress,
        question: Question,
        now: Date) -> KeyPress.Result
    {
        guard self.model.status(at: now) == .pending,
              let digit = keyPress.characters.first?.wholeNumberValue,
              self.model.toggleOption(questionID: question.questionid, optionNumber: digit)
        else { return .ignored }
        return .handled
    }
    #endif
}

@MainActor
struct OpenClawQuestionCards: View {
    let viewModel: OpenClawChatViewModel

    var body: some View {
        ForEach(self.viewModel.visibleQuestionCards) { card in
            OpenClawQuestionCard(model: card) { [weak viewModel = self.viewModel] model in
                await viewModel?.submitQuestion(model)
            } onSkip: { [weak viewModel = self.viewModel] model in
                await viewModel?.skipQuestion(model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
