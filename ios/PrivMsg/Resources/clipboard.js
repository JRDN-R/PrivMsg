// Keep native file paste separate from the permission-based clipboard button.
// The browser must expose file bytes; a filename or local path is not a file.
export function filesFromClipboard(data) {
  const files = Array.from(data?.files || []);
  if (files.length) return files;
  return Array.from(data?.items || [])
    .filter(item => item.kind === "file")
    .map(item => item.getAsFile())
    .filter(Boolean);
}

const TEXT_FORMATS = new Set(["text/plain", "text/html", "text/uri-list"]);
const EXTENSIONS = {
  "application/pdf": "pdf", "application/zip": "zip",
  "application/json": "json", "application/msword": "doc",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
  "application/vnd.ms-excel": "xls",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
  "text/plain": "txt", "text/html": "html", "text/csv": "csv",
  "text/markdown": "md", "image/png": "png", "image/jpeg": "jpg",
  "image/webp": "webp", "image/gif": "gif", "image/heic": "heic",
  "image/svg+xml": "svg", "audio/mpeg": "mp3", "audio/mp4": "m4a",
  "audio/wav": "wav", "audio/webm": "webm", "video/mp4": "mp4",
  "video/quicktime": "mov", "video/webm": "webm"
};

async function readClipboardItem(item, index) {
  // MIME entries are alternate representations of ONE clipboard item.
  // Prefer a file representation and never stage every image format twice.
  const types = Array.from(item.types || []);
  const fileTypes = types.filter(type => !TEXT_FORMATS.has(type));
  if (item.presentationStyle === "attachment") {
    fileTypes.push(...types.filter(type => TEXT_FORMATS.has(type)));
  }
  for (const type of fileTypes) {
    try {
      const blob = await item.getType(type);
      if (blob instanceof File && blob.name) return { file: blob };
      const extension = EXTENSIONS[type] || "bin";
      return { file: new File([blob], `pasted-${Date.now()}-${index + 1}.${extension}`, { type }) };
    } catch {
      // Try another representation if this browser cannot read the first.
    }
  }
  if (fileTypes.length) throw new Error("Could not read a clipboard file");
  if (types.includes("text/plain")) {
    return { text: await (await item.getType("text/plain")).text() };
  }
  return {};
}

export function installClipboardUploads({
  input, addFiles, insertText, closeMenu, canAcceptFiles, setReading, notify
}) {
  let reading = false;

  function acceptFiles() {
    if (canAcceptFiles()) return true;
    notify("Sign in and wait for the current upload to finish before adding files.");
    return false;
  }

  input.addEventListener("paste", event => {
    // Snapshot synchronously: clipboard data is only readable during paste.
    const files = filesFromClipboard(event.clipboardData);
    if (!files.length || event.defaultPrevented) return;
    event.preventDefault();
    if (!acceptFiles()) return;
    closeMenu();
    void Promise.resolve(addFiles(files)).catch(() => {
      notify("Could not add those files. Try Upload files.", true);
    });
  });

  async function pasteFromClipboard() {
    closeMenu();
    if (reading || !acceptFiles()) return;
    const clipboard = navigator.clipboard;
    if (!clipboard?.read && !clipboard?.readText) {
      showPasteHelp();
      return;
    }

    reading = true;
    setReading(true);
    try {
      const files = [];
      const text = [];
      let failed = false;
      if (clipboard.read) {
        const items = await clipboard.read();
        for (const [index, item] of items.entries()) {
          try {
            const result = await readClipboardItem(item, index);
            if (result.file) files.push(result.file);
            else if (result.text) text.push(result.text);
          } catch {
            failed = true;
          }
        }
      } else {
        text.push(await clipboard.readText());
      }
      // The user may have signed out while the permission prompt was open.
      if (!acceptFiles()) return;
      if (files.length) await addFiles(files);
      else if (text.some(Boolean)) insertText(text.join("\n"));
      else showPasteHelp();
      if (failed) notify("Some clipboard items could not be read. Use Upload files for those items.", true);
    } catch {
      showPasteHelp();
    } finally {
      reading = false;
      setReading(false);
    }
  }

  function showPasteHelp() {
    input.focus();
    notify("Paste in the message field (touch and hold on iPhone, or Ctrl+V / Cmd+V). If the file is unavailable, use Upload files.", true);
  }

  return { pasteFromClipboard };
}
