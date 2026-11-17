import UIKit
import QuickLook
import UniformTypeIdentifiers

/// This is a native drag source, not a web drag simulation. UIKit adds another
/// UIDragItem when the second finger taps a row during the current drag session.
@MainActor
final class AttachmentListViewController: UITableViewController, UITableViewDragDelegate, QLPreviewControllerDataSource {
    private let attachments: [NativeAttachment]
    private let store: AttachmentStore
    private var ready: [String: URL] = [:]
    private var loading: Set<String> = []
    private var percentages: [String: Int] = [:]
    private var failures: [String: String] = [:]
    private var previewURL: URL?
    private var sharing = false
    private var dragInProgress = false
    private let instruction = UILabel()
    private lazy var shareButton = UIBarButtonItem(title: "Share", style: .plain, target: self, action: #selector(shareSelection))

    init(attachments: [NativeAttachment], store: AttachmentStore) {
        self.attachments = attachments
        self.store = store
        super.init(style: .insetGrouped)
        title = "Files"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        tableView.dragDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItems = [editButtonItem, shareButton]
        editButtonItem.title = "Select"
        shareButton.isEnabled = false
        instruction.numberOfLines = 0
        instruction.font = .preferredFont(forTextStyle: .footnote)
        instruction.textColor = .secondaryLabel
        instruction.text = attachments.isEmpty
            ? "This conversation has no uploaded files yet. Add files to a message and send it first."
            : "Touch and hold a file, then tap more files with another finger. Keep holding while you switch apps and drop. Tap a file first to download and preview it."
        instruction.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView()
        header.addSubview(instruction)
        NSLayoutConstraint.activate([
            instruction.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            instruction.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            instruction.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            instruction.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12)
        ])
        tableView.tableHeaderView = header
        store.onProgress = { [weak self] id, value in
            guard let self else { return }
            self.percentages[id] = Int(value * 100)
            self.refreshRow(id)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let width = tableView.bounds.width
        let height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        if abs(header.frame.height - height) > 0.5 || header.frame.width != width {
            header.frame = CGRect(x: 0, y: 0, width: width, height: height)
            tableView.tableHeaderView = header
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        editButtonItem.title = editing ? "Done" : "Select"
        shareButton.isEnabled = editing && !(tableView.indexPathsForSelectedRows ?? []).isEmpty && !sharing
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { attachments.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
        configure(cell, attachment: attachments[indexPath.row])
        return cell
    }

    private func configure(_ cell: UITableViewCell, attachment: NativeAttachment) {
        var content = cell.defaultContentConfiguration()
        content.text = attachment.name
        content.textProperties.numberOfLines = 2
        content.image = UIImage(systemName: attachment.contentType.conforms(to: .image) ? "photo" : "doc")
        var detail = attachment.displaySize
        if loading.contains(attachment.id) { detail += " · Downloading \(percentages[attachment.id] ?? 0)%" }
        else if ready[attachment.id] != nil { detail += " · Ready to drag" }
        else if failures[attachment.id] != nil { detail += " · Download failed, tap to retry" }
        else { detail += " · Downloads original when needed" }
        content.secondaryText = detail
        cell.contentConfiguration = content
        cell.accessoryType = ready[attachment.id] != nil ? .checkmark : .none
        cell.accessibilityHint = "Touch and hold to drag this file. Tap to download and preview."
    }

    private func refreshRow(_ id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) else { return }
        // Do not reload rows during a drag: UIKit must preserve its drag source.
        configure(cell, attachment: attachments[index])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isEditing {
            shareButton.isEnabled = !sharing
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        guard !dragInProgress else { return }
        let attachment = attachments[indexPath.row]
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.prepare(attachment)
                guard self.viewIfLoaded?.window != nil else { return }
                self.previewURL = url
                let preview = QLPreviewController()
                preview.dataSource = self
                self.present(preview, animated: true)
            } catch { self.showError(error) }
        }
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if isEditing { shareButton.isEnabled = !(tableView.indexPathsForSelectedRows ?? []).isEmpty && !sharing }
    }

    // Editing is selection-only. The native sheet never deletes remote files.
    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }

    private func prepare(_ attachment: NativeAttachment) async throws -> URL {
        loading.insert(attachment.id)
        failures.removeValue(forKey: attachment.id)
        refreshRow(attachment.id)
        defer { loading.remove(attachment.id); refreshRow(attachment.id) }
        do {
            let url = try await store.fileURL(for: attachment)
            try Task.checkCancellation()
            ready[attachment.id] = url
            return url
        } catch {
            ready.removeValue(forKey: attachment.id)
            failures[attachment.id] = error.localizedDescription
            throw error
        }
    }

    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        // UIKit calls this once for each selected row; returning the selection
        // again here would add the same files multiple times.
        let attachment = attachments[indexPath.row]
        guard !session.items.contains(where: { ($0.localObject as? String) == attachment.id }) else { return [] }
        return [dragItem(for: attachment)]
    }

    func tableView(_ tableView: UITableView, itemsForAddingTo session: UIDragSession, at indexPath: IndexPath, point: CGPoint) -> [UIDragItem] {
        let attachment = attachments[indexPath.row]
        guard !session.items.contains(where: { ($0.localObject as? String) == attachment.id }) else { return [] }
        return [dragItem(for: attachment)]
    }

    func tableView(_ tableView: UITableView, dragSessionAllowsMoveOperation session: UIDragSession) -> Bool { false }
    func tableView(_ tableView: UITableView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { false }
    func tableView(_ tableView: UITableView, dragSessionWillBegin session: UIDragSession) { dragInProgress = true }
    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) { dragInProgress = false }

    private func dragItem(for attachment: NativeAttachment) -> UIDragItem {
        let provider = NSItemProvider()
        provider.suggestedName = attachment.safeFilename
        let store = self.store
        let sessionGeneration = store.sessionGeneration
        // Start ONE preparation task while still in the foreground. The target
        // app's later provider request must never need a fresh WebKit round trip.
        let preparation = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            do { return try await self.prepare(attachment) }
            catch {
                if !(error is CancellationError) { self.instruction.text = error.localizedDescription + " Tap the file to retry." }
                throw error
            }
        }
        // The provider retains the store. The completed cache file remains alive
        // after the sheet closes and while the receiving app copies its bytes.
        provider.registerFileRepresentation(forTypeIdentifier: attachment.contentType.identifier,
            fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task { @MainActor in
                do {
                    let url = try await preparation.value
                    try Task.checkCancellation()
                    guard store.sessionGeneration == sessionGeneration,
                          FileManager.default.fileExists(atPath: url.path) else { throw AttachmentError.unauthorized }
                    progress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch { completion(nil, false, error) }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        let item = UIDragItem(itemProvider: provider)
        item.localObject = attachment.id
        return item
    }

    @objc private func shareSelection() {
        let selected = (tableView.indexPathsForSelectedRows ?? []).sorted().map { attachments[$0.row] }
        guard !selected.isEmpty, !sharing else { return }
        sharing = true
        shareButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer { self.sharing = false; self.shareButton.isEnabled = !(self.tableView.indexPathsForSelectedRows ?? []).isEmpty }
            do {
                var urls: [URL] = []
                for attachment in selected { urls.append(try await self.prepare(attachment)) }
                guard self.viewIfLoaded?.window != nil else { return }
                let share = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                share.popoverPresentationController?.barButtonItem = self.shareButton
                self.present(share, animated: true)
            } catch { self.showError(error) }
        }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewURL! as NSURL }

    private func showError(_ error: Error) {
        guard !(error is CancellationError), viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "File unavailable", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func close() { dismiss(animated: true) }
}
