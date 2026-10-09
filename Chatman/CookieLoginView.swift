import SwiftUI
import WebKit
import ChatmanKit

/// Signing in on the network's own page.
///
/// Messenger, Instagram, X and LinkedIn have no code to scan and no password anyone else may
/// hold. What they have is their own login page, and what a bridge needs afterwards is a
/// handful of named values that page leaves behind. So the page is shown as it is — the real
/// one, on its real address — and when it has finished, exactly the values the bridge asked
/// for are read out and sent on. Nothing else is kept, and the browser it runs in is thrown
/// away with the screen.
struct CookieLoginView: View {
    let network: ChatNetwork
    let request: MatrixAPI.BridgeLoginStep.Cookies
    let onCollected: ([String: String]) -> Void
    let onGiveUp: () -> Void

    @State private var collected: [String: String] = [:]
    @State private var isReady = false

    var body: some View {
        VStack(spacing: 0) {
            if request.hidden == true {
                ProgressView("Signing in")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CookieWebView(request: request, collected: $collected)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Text(isReady
                     ? "Signed in. Finishing up…"
                     : "Sign in as you normally would. Chatman only keeps what \(network.displayName) hands back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // A way out that isn't the back button, because a page that never finishes
                // otherwise leaves someone stuck looking at a website.
                if !isReady {
                    Button("This isn't working") { onGiveUp() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .onChange(of: collected) { _, values in
            guard !values.isEmpty, !isReady else { return }
            isReady = true
            onCollected(values)
        }
    }
}

/// The browser itself, and the thing that reads the values out of it.
private struct CookieWebView: UIViewRepresentable {
    let request: MatrixAPI.BridgeLoginStep.Cookies
    @Binding var collected: [String: String]

    func makeCoordinator() -> Coordinator {
        Coordinator(request: request) { values in
            collected = values
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Its own jar. Nothing here touches Safari's cookies, and closing the screen throws
        // the whole session away rather than leaving someone signed in somewhere invisible.
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        if let agent = request.userAgent, !agent.isEmpty {
            webView.customUserAgent = agent
        }

        if let url = URL(string: request.url) {
            webView.load(URLRequest(url: url))
        }

        context.coordinator.watch(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let request: MatrixAPI.BridgeLoginStep.Cookies
        private let onCollected: ([String: String]) -> Void
        private var observation: NSKeyValueObservation?
        private var finished = false

        init(
            request: MatrixAPI.BridgeLoginStep.Cookies,
            onCollected: @escaping ([String: String]) -> Void
        ) {
            self.request = request
            self.onCollected = onCollected
        }

        /// The address bar is the other half of the signal: some networks only hand over what
        /// the bridge needs once they've redirected somewhere in particular.
        func watch(_ webView: WKWebView) {
            observation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in await self?.collect(from: view) }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in await collect(from: webView) }
        }

        private func collect(from webView: WKWebView) async {
            guard !finished else { return }

            var values: [String: String] = [:]

            // Whatever the bridge's own snippet can find, first: it knows things about the
            // page that no general rule does.
            if let script = request.extractJS, !script.isEmpty {
                for (key, value) in await run(script, in: webView) {
                    values[key] = value
                }
            }

            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()

            for field in request.fields where values[field.name] == nil {
                switch field.type {
                case .cookie:
                    let match = cookies.first { cookie in
                        guard cookie.name == field.name else { return false }
                        guard let domain = field.cookieDomain, !domain.isEmpty else { return true }
                        return cookie.domain.hasSuffix(domain)
                            || domain.hasSuffix(cookie.domain)
                    }
                    if let match { values[field.name] = match.value }

                case .localStorage:
                    let escaped = field.name.replacingOccurrences(of: "'", with: "\\'")
                    if let value = try? await webView.evaluateJavaScript(
                        "localStorage.getItem('\(escaped)')"
                    ) as? String {
                        values[field.name] = value
                    }

                case .requestHeader, .requestBody, .special:
                    // Only the bridge's own snippet can produce these; there's nothing to
                    // read out of the page for them.
                    break
                }
            }

            // Every field the bridge asked for and could plausibly get.
            let wanted = request.fields.filter { field in
                switch field.type {
                case .cookie, .localStorage: true
                default: request.extractJS != nil
                }
            }

            guard !wanted.isEmpty, wanted.allSatisfy({ values[$0.name] != nil }) else { return }
            guard matchesFinalPage(webView.url) else { return }

            finished = true
            observation = nil
            onCollected(values)
        }

        /// Runs the bridge's own extraction snippet.
        ///
        /// It's written to evaluate to a promise, so it goes in as the body of an async
        /// function. Snippets that are a bare expression rather than a `return` get a second
        /// attempt with one added.
        private func run(_ script: String, in webView: WKWebView) async -> [String: String] {
            if let result = try? await webView.callAsyncJavaScript(
                script, arguments: [:], contentWorld: .page
            ) {
                return strings(from: result)
            }

            if let result = try? await webView.callAsyncJavaScript(
                "return await (\(script));", arguments: [:], contentWorld: .page
            ) {
                return strings(from: result)
            }

            return [:]
        }

        private func strings(from result: Any?) -> [String: String] {
            guard let dictionary = result as? [String: Any] else { return [:] }

            return dictionary.compactMapValues { value in
                if let text = value as? String { return text }
                if let number = value as? NSNumber { return number.stringValue }
                return nil
            }
        }

        /// Whether the page has reached wherever the bridge said to wait for.
        private func matchesFinalPage(_ url: URL?) -> Bool {
            guard let pattern = request.waitForURLPattern, !pattern.isEmpty else { return true }
            guard let address = url?.absoluteString else { return false }
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }

            let range = NSRange(address.startIndex..., in: address)
            return expression.firstMatch(in: address, range: range) != nil
        }
    }
}
