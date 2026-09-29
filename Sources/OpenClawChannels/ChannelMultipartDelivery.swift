import Foundation

/// Delivers the parts of one outbound message (text chunks, request batches, text followed by
/// attachments) in order without ever re-sending a part that was already delivered.
///
/// A failure of the first part propagates unchanged: nothing was delivered, so the registry's
/// classified retry stays safe. Once a part was delivered, a later part is retried here, but only
/// when its failure is safe to retry (``ChannelSendError/rateLimited(retryAfterMs:)`` and
/// ``ChannelSendError/notSent(underlying:retryAfterMs:)``, honoring Retry-After). Any other
/// failure, or a retryable one that persists, becomes
/// ``ChannelSendError/partiallyDelivered(receipt:failure:)`` carrying the delivered parts, which
/// ``ChannelRegistry`` never retries (upstream `ChannelPartialDeliveryError`).
struct ChannelMultipartDelivery {
    /// Attempts per part after the first part was delivered.
    var maxPartAttempts = 3
    /// Backoff when a retryable failure has no Retry-After.
    var backoffMs = 500
    /// Thread recorded on a partial receipt.
    var threadID: String?
    /// Replied-to message recorded on a partial receipt.
    var replyToID: String?

    /// Sends `count` parts in order.
    /// - Parameters:
    ///   - count: Number of parts.
    ///   - isolation: Caller isolation (the adapter actor).
    ///   - sendPart: Sends one part and returns its receipt parts (possibly empty).
    /// - Returns: Receipt parts of every delivered part, in order.
    func run(
        count: Int,
        isolation _: isolated (any Actor)? = #isolation,
        _ sendPart: (Int) async throws -> [ChannelSendReceipt.Part]
    ) async throws -> [ChannelSendReceipt.Part] {
        var delivered: [ChannelSendReceipt.Part] = []
        for index in 0..<count {
            if index == 0 {
                delivered += try await sendPart(index)
                continue
            }
            var attempt = 1
            while true {
                do {
                    delivered += try await sendPart(index)
                    break
                } catch {
                    let classification = ChannelSendError.classify(error)
                    if classification.isRetryable, attempt < self.maxPartAttempts, !Task.isCancelled {
                        let delayMs = classification.retryAfterMs ?? self.backoffMs * attempt
                        await ChannelAsync.sleep(milliseconds: delayMs)
                        attempt += 1
                        continue
                    }
                    throw self.partial(delivered: delivered, failure: classification)
                }
            }
        }
        return delivered
    }

    /// Builds the partial-delivery error for parts delivered so far.
    /// - Parameters:
    ///   - delivered: Receipt parts already delivered.
    ///   - failure: Classified failure of the next part.
    /// - Returns: ``ChannelSendError/partiallyDelivered(receipt:failure:)``.
    func partial(delivered: [ChannelSendReceipt.Part], failure: ChannelSendError) -> ChannelSendError {
        if case .partiallyDelivered(let inner, let innerFailure) = failure {
            let combined = ChannelSendReceipt.combined([self.receipt(delivered), inner]) ?? inner
            return .partiallyDelivered(receipt: combined, failure: innerFailure)
        }
        return .partiallyDelivered(receipt: self.receipt(delivered), failure: failure)
    }

    private func receipt(_ parts: [ChannelSendReceipt.Part]) -> ChannelSendReceipt {
        ChannelSendReceipt(parts: parts, threadID: self.threadID, replyToID: self.replyToID)
    }
}
