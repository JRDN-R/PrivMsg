import UIKit

/// A real share destination: the user reviews the original files, then explicitly
/// uploads them to PrivMsg. No parent-app launch or shared-container entitlement.
@MainActor
final class ShareViewController: UIViewController, UITextViewDelegate {
    private let backend = ShareBackend()
    private var reader: ShareItemReader?
    private var input: ShareInput?
    private var draft: ShareDraft?
    private var prepareTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var started = false
    private var busy = true
    private var authenticated = false
    private var finishing = false
    private var retrying = false

    private let cancelButton = UIButton(type: .system)
    private let accountButton = UIButton(type: .system)
    private let filesLabel = UILabel()
    private let destinationLabel = UILabel()
    private let linkNotice = UILabel()
    private let messageView = UITextView()
    private let loginStack = UIStackView()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let loginButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 540, height: 680)
        isModalInPresentation = true
        buildInterface()
        updateControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        prepareTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reader = try ShareItemReader()
                self.reader = reader
                let shared = try await reader.read(self.extensionContext?.inputItems as? [NSExtensionItem] ?? [])
                try Task.checkCancellation()
                self.input = shared
                self.messageView.text = shared.text
                self.filesLabel.text = shared.files.isEmpty ? "Shared text" : shared.files.map {
                    "\($0.name)  ·  \(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file))"
                }.joined(separator: "\n")
                self.linkNotice.isHidden = !shared.files.isEmpty || !shared.text.contains("://")
                self.authenticated = try await self.backend.restoreSignIn()
                self.statusLabel.text = self.authenticated ? "Ready to send." : "Sign in once to use PrivMsg from the share sheet."
            } catch is CancellationError { return }
            catch {
                if !self.finishing { self.statusLabel.text = error.localizedDescription }
            }
            self.busy = false
            self.updateControls()
        }
    }

    private func buildInterface() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        let title = UILabel()
        title.text = "Send to PrivMsg"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        let header = UIStackView(arrangedSubviews: [cancelButton, title])
        header.spacing = 12
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        content.addArrangedSubview(header)

        destinationLabel.text = "Today's conversation"
        destinationLabel.font = .preferredFont(forTextStyle: .title2)
        destinationLabel.accessibilityTraits = .header
        content.addArrangedSubview(destinationLabel)
        filesLabel.text = "Preparing shared items…"
        filesLabel.font = .preferredFont(forTextStyle: .subheadline)
        filesLabel.numberOfLines = 0
        content.addArrangedSubview(filesLabel)
        linkNotice.text = "The source app shared a link. To upload the actual file, share the file itself or save it to Files first."
        linkNotice.font = .preferredFont(forTextStyle: .footnote)
        linkNotice.textColor = .secondaryLabel
        linkNotice.numberOfLines = 0
        linkNotice.isHidden = true
        content.addArrangedSubview(linkNotice)

        let messageLabel = UILabel()
        messageLabel.text = "Message (optional with files)"
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        content.addArrangedSubview(messageLabel)
        messageView.delegate = self
        messageView.font = .preferredFont(forTextStyle: .body)
        messageView.backgroundColor = .secondarySystemBackground
        messageView.layer.cornerRadius = 12
        messageView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        messageView.accessibilityLabel = "Message"
        messageView.heightAnchor.constraint(equalToConstant: 130).isActive = true
        content.addArrangedSubview(messageView)

        loginStack.axis = .vertical
        loginStack.spacing = 10
        let loginExplanation = UILabel()
        loginExplanation.text = "Use your PrivMsg username and password. Your password is not saved."
        loginExplanation.numberOfLines = 0
        loginExplanation.textColor = .secondaryLabel
        loginExplanation.font = .preferredFont(forTextStyle: .footnote)
        loginStack.addArrangedSubview(loginExplanation)
        usernameField.placeholder = "PrivMsg username"
        usernameField.text = "rapp"
        usernameField.textContentType = .username
        usernameField.autocapitalizationType = .none
        usernameField.autocorrectionType = .no
        usernameField.borderStyle = .roundedRect
        usernameField.accessibilityLabel = "PrivMsg username"
        usernameField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        loginStack.addArrangedSubview(usernameField)
        passwordField.placeholder = "PrivMsg password"
        passwordField.textContentType = .password
        passwordField.isSecureTextEntry = true
        passwordField.borderStyle = .roundedRect
        passwordField.accessibilityLabel = "PrivMsg password"
        passwordField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        loginStack.addArrangedSubview(passwordField)
        loginButton.setTitle("Sign in to share", for: .normal)
        loginButton.addTarget(self, action: #selector(signIn), for: .touchUpInside)
        loginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        loginStack.addArrangedSubview(loginButton)
        content.addArrangedSubview(loginStack)

        sendButton.configuration = .filled()
        sendButton.configuration?.cornerStyle = .large
        sendButton.setTitle("Send to PrivMsg", for: .normal)
        sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        content.addArrangedSubview(sendButton)
        progressView.isHidden = true
        content.addArrangedSubview(progressView)
        statusLabel.text = "Preparing shared items…"
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityTraits = .updatesFrequently
        content.addArrangedSubview(statusLabel)
        accountButton.setTitle("Sign out of share sheet", for: .normal)
        accountButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        accountButton.addTarget(self, action: #selector(signOut), for: .touchUpInside)
        content.addArrangedSubview(accountButton)
    }

    private func updateControls() {
        let ready = input != nil
        let message = messageView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !(input?.files.isEmpty ?? true) || !message.isEmpty
        loginStack.isHidden = authenticated || !ready
        loginButton.isEnabled = !busy && !finishing
        usernameField.isEnabled = !busy && !finishing
        passwordField.isEnabled = !busy && !finishing
        messageView.isEditable = ready && !busy && !finishing && draft == nil
        sendButton.isEnabled = ready && authenticated && !busy && !finishing && hasContent && message.utf8.count <= 100_000
        sendButton.setTitle(retrying ? "Retry send" : "Send to PrivMsg", for: .normal)
        accountButton.isHidden = !authenticated
        accountButton.isEnabled = !busy && !finishing && draft == nil
        cancelButton.isEnabled = !finishing
    }

    func textViewDidChange(_ textView: UITextView) {
        if textView.text.utf8.count > 100_000 { statusLabel.text = "Keep the message under 100 KB, or share it as a text file." }
        updateControls()
    }

    @objc private func signIn() {
        guard !busy && !finishing else { return }
        let username = usernameField.text ?? ""
        let password = passwordField.text ?? ""
        passwordField.text = nil
        view.endEditing(true)
        busy = true
        statusLabel.text = "Signing in…"
        updateControls()
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.backend.signIn(username: username, password: password)
                try Task.checkCancellation()
                self.authenticated = true
                self.statusLabel.text = "Ready to send."
            } catch is CancellationError { return }
            catch { if !self.finishing { self.statusLabel.text = error.localizedDescription } }
            self.busy = false
            self.updateControls()
        }
    }

    @objc private func signOut() {
        guard !busy && !finishing && draft == nil else { return }
        busy = true
        updateControls()
        actionTask = Task { [weak self] in
            guard let self else { return }
            await self.backend.signOut()
            self.authenticated = false
            self.busy = false
            self.statusLabel.text = "Signed out of the share sheet."
            self.updateControls()
        }
    }

    @objc private func send() {
        guard !busy && !finishing && authenticated, let input else { return }
        view.endEditing(true)
        let text = messageView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!input.files.isEmpty || !text.isEmpty), text.utf8.count <= 100_000 else { return }
        if draft == nil { draft = ShareDraft(files: input.files, text: text) }
        guard let draft else { return }
        busy = true
        progressView.isHidden = false
        statusLabel.text = "Connecting to PrivMsg…"
        updateControls()
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.backend.send(draft) { [weak self] progress, status in
                    Task { @MainActor [weak self] in
                        guard let self, !self.finishing else { return }
                        self.progressView.progress = Float(progress)
                        self.statusLabel.text = status
                    }
                }
                try Task.checkCancellation()
                self.finishing = true
                self.statusLabel.text = "Sent to today's conversation."
                self.updateControls()
                self.reader?.cleanup()
                self.extensionContext?.completeRequest(returningItems: nil)
            } catch is CancellationError { return }
            catch {
                guard !self.finishing else { return }
                if case ShareFailure.signInRequired = error { self.authenticated = false }
                self.retrying = true
                self.busy = false
                self.statusLabel.text = error.localizedDescription
                self.updateControls()
            }
        }
    }

    @objc private func cancel() {
        guard !finishing else { return }
        finishing = true
        view.endEditing(true)
        prepareTask?.cancel()
        actionTask?.cancel()
        updateControls()
        statusLabel.text = "Closing…"
        Task { [weak self] in
            guard let self else { return }
            await self.prepareTask?.value
            await self.actionTask?.value
            await self.backend.discardUnpublished(self.draft)
            self.reader?.cleanup()
            self.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}
