import UIKit
import WebKit

private struct NativeSnapshot: Decodable {
    let type: String
    let signedIn: Bool
    let uid: String
    let threadID: String
    let attachments: [NativeAttachment]
    let unavailable: Int
}

@MainActor
final class PrivMsgViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    private var webView: WKWebView!
    private var server: LocalWebServer?
    private var snapshot: NativeSnapshot?
    private var cachedSession: NativeSession?
    private var sessionCachedAt = Date.distantPast
    private let loading = UIStackView()
    private let loadingLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var timeout: Task<Void, Never>?
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]
    private lazy var filesButton = UIBarButtonItem(title: "Files", image: UIImage(systemName: "doc.on.doc"), target: self, action: #selector(openFiles))
    private lazy var fileStore = AttachmentStore { [weak self] in
        guard let self else { throw AttachmentError.unauthorized }
        return try await self.nativeSession()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "PrivMsg"
        view.backgroundColor = UIColor(red: 0.067, green: 0.075, blue: 0.082, alpha: 1)
        let content = WKUserContentController()
        content.add(WeakMessageHandler(self), name: "privmsg")
        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        webView.scrollView.backgroundColor = view.backgroundColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        filesButton.isEnabled = false
        navigationItem.rightBarButtonItem = filesButton
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.confirmReload() },
            UIAction(title: "Clear downloaded copies", image: UIImage(systemName: "trash")) { [weak self] _ in
                self?.fileStore.clear()
                self?.clearWebDownloads()
                self?.showMessage("Downloaded copies cleared", "Your saved messages and original files are unchanged.")
            },
            UIAction(title: "Sign out", image: UIImage(systemName: "rectangle.portrait.and.arrow.right")) { [weak self] _ in self?.confirmSignOut() }
        ]))
        installLoadingView()
        clearWebDownloads()
        startApp()
    }

    private func installLoadingView() {
        loading.axis = .vertical
        loading.alignment = .center
        loading.spacing = 16
        loading.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.numberOfLines = 0
        loadingLabel.textAlignment = .center
        retryButton.setTitle("Try again", for: .normal)
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        loading.addArrangedSubview(loadingLabel)
        loading.addArrangedSubview(retryButton)
        view.addSubview(loading)
        NSLayoutConstraint.activate([
            loading.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loading.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82)
        ])
    }

    private func startApp(reload: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if server == nil {
                    guard let resources = Bundle.main.url(forResource: "WebContent", withExtension: nil) else {
                        throw NSError(domain: "PrivMsg", code: 1, userInfo: [NSLocalizedDescriptionKey: "The app's bundled files are missing. Run the installer again."])
                    }
                    server = LocalWebServer(resourceDirectory: resources)
                }
                guard let server else { return }
                try await server.start()
                if webView.url == nil || reload {
                    loading.isHidden = false
                    loadingLabel.text = "Opening your conversations…"
                    retryButton.isHidden = true
                    webView.isHidden = true
                    snapshot = nil
                    filesButton.isEnabled = false
                    webView.load(URLRequest(url: server.baseURL))
                    timeout?.cancel()
                    timeout = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 25_000_000_000)
                        guard !Task.isCancelled, let self, self.snapshot == nil else { return }
                        self.loadFailed("PrivMsg could not connect. Check your internet connection, then try again.")
                    }
                }
            } catch { loadFailed(error.localizedDescription) }
        }
    }

    @objc private func retry() { startApp(reload: true) }
    func resumeApp() {
        guard isViewLoaded else { return }
        startApp()
        if snapshot?.signedIn == true {
            Task { @MainActor [weak self] in _ = try? await self?.nativeSession(forceRefresh: true) }
        }
    }

    private func loadFailed(_ message: String) {
        timeout?.cancel()
        loading.isHidden = false
        webView.isHidden = true
        loadingLabel.text = message
        retryButton.isHidden = false
    }

    private func trusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "http" && url.host == "127.0.0.1" && url.port == Int(LocalWebServer.port)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "privmsg", message.frameInfo.isMainFrame,
              trusted(message.frameInfo.request.url), trusted(webView.url),
              JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body),
              let newSnapshot = try? JSONDecoder().decode(NativeSnapshot.self, from: data),
              newSnapshot.type == "snapshot" else { return }
        if snapshot?.uid != newSnapshot.uid {
            cachedSession = nil
            sessionCachedAt = .distantPast
            fileStore.clear()
            clearWebDownloads()
            if presentedViewController != nil { dismiss(animated: false) }
        }
        snapshot = newSnapshot
        filesButton.isEnabled = newSnapshot.signedIn
        filesButton.title = newSnapshot.attachments.isEmpty ? "Files" : "Files (\(newSnapshot.attachments.count))"
        timeout?.cancel()
        loading.isHidden = true
        webView.isHidden = false
    }

    private func nativeSession(forceRefresh: Bool = false) async throws -> NativeSession {
        guard trusted(webView.url), snapshot?.signedIn == true else { throw AttachmentError.unauthorized }
        // The destination app can request drag data after WebKit is suspended.
        // Refresh before showing Files, then retain the session only in memory.
        if let session = cachedSession, session.uid == snapshot?.uid,
           Date().timeIntervalSince(sessionCachedAt) < 45 * 60,
           (!forceRefresh && Date().timeIntervalSince(sessionCachedAt) < 5 * 60 || UIApplication.shared.applicationState != .active) {
            return session
        }
        guard UIApplication.shared.applicationState == .active else { throw AttachmentError.unauthorized }
        let value = try await webView.callAsyncJavaScript("return await window.PrivMsgNative.session(forceRefresh);", arguments: ["forceRefresh": forceRefresh], in: nil, contentWorld: .page)
        guard let value, JSONSerialization.isValidJSONObject(value) else { throw AttachmentError.unauthorized }
        let data = try JSONSerialization.data(withJSONObject: value)
        let session = try JSONDecoder().decode(NativeSession.self, from: data)
        guard session.uid == snapshot?.uid, session.projectID == "privmsg-stream", !session.token.isEmpty else { throw AttachmentError.unauthorized }
        cachedSession = session
        sessionCachedAt = Date()
        return session
    }

    @objc private func openFiles() {
        guard let snapshot, snapshot.signedIn, presentedViewController == nil else { return }
        filesButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.filesButton.isEnabled = self.snapshot?.signedIn == true }
            do {
                _ = try await self.nativeSession(forceRefresh: true)
                guard self.snapshot?.uid == snapshot.uid, self.presentedViewController == nil else { return }
                let files = AttachmentListViewController(attachments: snapshot.attachments, store: self.fileStore)
                if snapshot.unavailable > 0 { files.navigationItem.prompt = "Some files have incomplete saved information." }
                let navigation = UINavigationController(rootViewController: files)
                navigation.overrideUserInterfaceStyle = .dark
                navigation.modalPresentationStyle = .fullScreen
                self.present(navigation, animated: true)
            } catch { self.showMessage("Could not open files", "Check your connection and sign-in, then try again.") }
        }
    }

    private func confirmReload() {
        confirm(title: "Reload PrivMsg?", message: "Unsent changes on this screen will be cleared.", action: "Reload") { [weak self] in self?.startApp(reload: true) }
    }

    private func confirmSignOut() {
        confirm(title: "Sign out?", message: "Unsent changes and downloaded copies on this iPhone will be cleared.", action: "Sign out") { [weak self] in
            guard let self, self.trusted(self.webView.url) else { return }
            Task { @MainActor in
                do {
                    _ = try await self.webView.callAsyncJavaScript("return await window.PrivMsgNative.signOut();", arguments: [:], in: nil, contentWorld: .page)
                    self.fileStore.clear()
                    self.cachedSession = nil
                    self.clearWebDownloads()
                } catch { self.showMessage("Could not sign out", "Wait for any upload or recording to finish, then try again.") }
            }
        }
    }

    private func confirm(title: String, message: String, action: String, perform: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .default) { _ in perform() })
        present(alert, animated: true)
    }

    private func showMessage(_ title: String, _ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func clearWebDownloads() {
        for download in activeDownloads.values { download.cancel { _ in } }
        activeDownloads.removeAll()
        downloads.removeAll()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PrivMsgWebDownloads", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == false, url.scheme == "https",
           url.host == "privmsg-stream.firebaseapp.com", url.path == "/__/auth/iframe" {
            // Firebase Auth uses this exact subframe. It cannot call our bridge.
            decisionHandler(.allow)
        } else if trusted(webView.url), snapshot?.signedIn == true,
                  (trusted(url) && action.shouldPerformDownload || url.absoluteString.hasPrefix("blob:http://127.0.0.1:47835/")) {
            decisionHandler(.download)
        } else if trusted(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { loadFailed("PrivMsg could not open. Try again.") }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { startApp(reload: true) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard trusted(frame.request.url), presentedViewController == nil else { completionHandler(); return }
        let alert = UIAlertController(title: "PrivMsg", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard trusted(frame.request.url), presentedViewController == nil else { completionHandler(false); return }
        let alert = UIAlertController(title: "PrivMsg", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(trusted(frame.request.url) ? .prompt : .deny)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        activeDownloads[ObjectIdentifier(download)] = download
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivMsgWebDownloads", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            let leaf = (suggestedFilename as NSString).lastPathComponent
            let destination = root.appendingPathComponent(leaf.isEmpty || leaf == "." || leaf == ".." ? "Attachment" : leaf)
            downloads[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        } catch { completionHandler(nil) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        guard let url = downloads.removeValue(forKey: ObjectIdentifier(download)), presentedViewController == nil else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.barButtonItem = filesButton
        present(share, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        if let url = downloads.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        showMessage("Download failed", "Try opening the attachment from Files.")
    }
}

@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
