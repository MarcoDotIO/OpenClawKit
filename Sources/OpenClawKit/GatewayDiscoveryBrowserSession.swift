import Network

/// Browses every gateway service domain (``OpenClawBonjour/gatewayServiceDomains``) and reports
/// per-domain state and results on the main actor.
///
/// Starting a browser triggers the iOS local-network permission prompt. Call ``start(queueLabelPrefix:onState:onResults:)``
/// from gateway setup (after onboarding explains why), never at app launch. Callbacks from a stopped
/// generation are dropped.
@MainActor
public final class GatewayDiscoveryBrowserSession {
    private var browsers: [String: NWBrowser] = [:]
    private var states: [String: NWBrowser.State] = [:]
    private var generation: UInt64 = 0

    /// Creates an idle session.
    public init() {}

    /// Whether any browser is running.
    public var isRunning: Bool {
        !self.browsers.isEmpty
    }

    /// Starts browsing all gateway domains; a no-op while already running.
    ///
    /// - Parameters:
    ///   - queueLabelPrefix: Prefix for the per-domain dispatch queue labels.
    ///   - onState: Called with the domain, its new state and the combined status text.
    ///   - onResults: Called with the domain and its current results.
    public func start(
        queueLabelPrefix: String,
        onState: @escaping @MainActor (String, NWBrowser.State, String) -> Void,
        onResults: @escaping @MainActor (String, Set<NWBrowser.Result>) -> Void)
    {
        guard !self.isRunning else { return }
        self.generation &+= 1
        let generation = self.generation
        for domain in OpenClawBonjour.gatewayServiceDomains {
            self.browsers[domain] = GatewayDiscoveryBrowserSupport.makeBrowser(
                serviceType: OpenClawBonjour.gatewayServiceType,
                domain: domain,
                queueLabelPrefix: queueLabelPrefix,
                onState: { [weak self] state in
                    guard let self, self.generation == generation else { return }
                    self.states[domain] = state
                    let status = GatewayDiscoveryStatusText.make(
                        states: Array(self.states.values), hasBrowsers: self.isRunning)
                    onState(domain, state, status)
                },
                onResults: { [weak self] results in
                    guard let self, self.generation == generation else { return }
                    onResults(domain, results)
                })
        }
    }

    /// Cancels every browser and drops late callbacks.
    public func stop() {
        self.generation &+= 1
        for browser in self.browsers.values {
            browser.cancel()
        }
        self.browsers = [:]
        self.states = [:]
    }
}
