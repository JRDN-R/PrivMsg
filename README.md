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

The [native iPhone app](ios/README.md) keeps this web interface and adds a native
**Files** screen. Hold one file, tap others with a second finger, then switch
apps and drop. It also provides Quick Look and multi-file sharing. Install or
renew it from your Mac using `bash Install-PrivMsg.command` and Xcode. The root
installer also works as a standalone download and keeps its project under
`~/Developer/PrivMsg-iOS`.
Adding the website to the Home Screen alone does not provide the native layer.

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
