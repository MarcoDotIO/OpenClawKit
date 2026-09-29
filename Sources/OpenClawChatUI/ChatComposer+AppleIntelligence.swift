import Foundation
import OpenClawKit

// Apple Foundation Models integration for the composer.
//
// - `apple-fm/system` (on-device) does not reason, so the thinking control stays hidden for it
//   (`OpenClawChatViewModel.hidesThinkingControl`); Private Cloud Compute (`apple-fm/private-cloud-compute`,
//   alias `pcc`) keeps it.
// - When Private Cloud Compute is selected and its quota is exhausted, the composer shows a notice with the system's
//   limit-increase offer (`FoundationModelsProvider.presentPrivateCloudQuotaIncreaseSuggestion()`).
// - Picked and pasted images are sent as `image` chat attachments; the agent runtime hands them to the apple-fm
//   provider as `MediaAttachment`s (labelled image-1…N, with the Vision tools on offer).

extension OpenClawChatViewModel {
    /// Provider/model pair the composer controls describe (selected model, then session, then defaults).
    var composerModelReference: ThinkingModelReference? {
        let session = self.currentSessionEntry()
        return Self.thinkingModelReference(
            session: session,
            defaults: self.sessionDefaults,
            modelChoice: self.selectedModelChoice(for: session))
    }

    /// Whether the effective model is Apple Private Cloud Compute.
    var isPrivateCloudComputeSelected: Bool {
        guard let reference = self.composerModelReference else { return false }
        return Self.isPrivateCloudComputeModel(providerID: reference.providerID, modelID: reference.modelID)
    }

    nonisolated static func isPrivateCloudComputeModel(providerID: String, modelID: String) -> Bool {
        guard OpenClawReferenceProviderCatalog.normalize(providerID: providerID) == FoundationModelsProvider.providerID
        else { return false }
        return AppleFoundationModelTarget(modelID: modelID) == .privateCloudCompute
    }
}

/// Presentation state for the Private Cloud Compute quota notice.
struct ChatPrivateCloudQuotaNotice: Equatable {
    let message: String
    let canRequestIncrease: Bool

    /// `nil` unless PCC is selected and its quota is exhausted.
    init?(isPrivateCloudComputeSelected: Bool, quota: FoundationModelsQuotaSnapshot?, now: Date = Date()) {
        guard isPrivateCloudComputeSelected, let quota, quota.limitReached else { return nil }
        if let resetDate = quota.resetDate, resetDate > now {
            self.message = String(
                format: String(localized: "Private Cloud Compute limit reached. It resets %@."),
                resetDate.formatted(.relative(presentation: .named)))
        } else {
            self.message = String(localized: "Private Cloud Compute limit reached.")
        }
        self.canRequestIncrease = quota.canRequestIncrease
    }
}

#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// Composer row shown while the selected Private Cloud Compute model is over quota.
@MainActor
struct ChatPrivateCloudQuotaRow: View {
    let viewModel: OpenClawChatViewModel
    @State private var notice: ChatPrivateCloudQuotaNotice?

    var body: some View {
        Group {
            if let notice {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(OpenClawChatTheme.warning)
                        .accessibilityHidden(true)
                    Text(notice.message)
                        .font(OpenClawChatTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if notice.canRequestIncrease {
                        Button {
                            if !FoundationModelsProvider.presentPrivateCloudQuotaIncreaseSuggestion() {
                                self.refresh()
                            }
                        } label: {
                            Text("Request More")
                                .font(OpenClawChatTypography.captionSemiBold)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("chat-composer-pcc-quota-increase")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-composer-pcc-quota")
            }
        }
        .task(id: self.refreshKey) { self.refresh() }
    }

    /// Re-read the quota when the model changes and after each run or error (the quota moves with usage).
    private var refreshKey: String {
        [
            self.viewModel.isPrivateCloudComputeSelected ? "pcc" : "",
            self.viewModel.modelSelectionID,
            String(self.viewModel.pendingRunCount),
            self.viewModel.errorText ?? "",
        ].joined(separator: "|")
    }

    private func refresh() {
        let selected = self.viewModel.isPrivateCloudComputeSelected
        self.notice = ChatPrivateCloudQuotaNotice(
            isPrivateCloudComputeSelected: selected,
            quota: selected ? FoundationModelsProvider.privateCloudQuota() : nil)
    }
}
#endif
