# PrivMsg

Paste files directly into the message field to add attachments, then press Send
to upload them with the message. Multiple files are supported. Original file
bytes, filenames and MIME types are retained when the browser supplies them.
Text-only paste continues to insert text at the cursor.

The attachment menu's **Paste from clipboard** button also accepts file formats
exposed by the browser's Clipboard API. Alternate formats of one clipboard item
produce one attachment. If filenames are unavailable, the button assigns names.
Browser permissions and supported clipboard formats vary, especially on iOS.
If pasting a copied file does not expose an attachment, use **Upload files**.
Copying a filename, path or URL alone does not upload the underlying file.

The exact iOS gesture of holding one file, tapping more files into the same drag,
and dropping them into another app requires native drag-session integration for
reliable control. Adding the website to the Home Screen does not provide those
APIs. A native iOS shell could retain the web app while implementing attachment
dragging with `UIDragInteraction`, `UIDragItem` and `NSItemProvider`.

References: [Apple drag-item delivery](https://developer.apple.com/documentation/uikit/data-delivery-with-drag-and-drop),
[web drag data-store rules](https://html.spec.whatwg.org/multipage/dnd.html#the-drag-data-store).

Run clipboard regression tests with Node.js 22 or newer:

```sh
node --test tests/clipboard.test.mjs
```

Device checks: paste a PDF and multiple files, verify attachment names, send and
download them, and compare the originals. Repeat with a screenshot, ordinary
text, clipboard permission denied, and iPhone's native Paste menu. The Send
button and Enter must both wait until attachments finish preparing.
