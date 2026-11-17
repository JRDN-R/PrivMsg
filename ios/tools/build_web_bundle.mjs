import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';

const ios = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.resolve(ios, '..');
const resources = path.join(ios, 'PrivMsg/WebContent');
const entry = await fs.readFile(path.join(repo, 'index.html'), 'utf8');
const base = await fs.readFile(path.join(ios, 'vendor/base-index.html'), 'utf8');
let html;
await vm.runInNewContext(entry.match(/<script>([\s\S]*?)<\/script>/)[1], {
  fetch: async () => ({ ok: true, text: async () => base }),
  document: { open() {}, close() {}, write(value) { html = value; }, body: {} }, console
});
if (!html?.includes('installClipboardUploads({')) throw new Error('The web compatibility patches did not apply.');
// Branding is packaged with the app, including the sign-in screen. No image
// request depends on GitHub Pages or another remote host.
html = html.replace(/<div class="auth-mark" aria-hidden="true">[\s\S]*?<\/div>/,
  '<img class="auth-mark privmsg-brand-mark" src="app-icon.png" alt="Vagaries" width="240" height="80">');
html = html.replace('<h1 id="authTitle">PrivMsg</h1>', '<h1 id="authTitle">Sign in</h1>');
html = html.replace('Enter your PrivMsg username and password', 'Enter your username and password');
html = html.replace(/<img\s+class="identity-logo"[\s\S]*?>/,
  '<img class="identity-logo" src="app-icon.png" alt="Vagaries" width="168" height="56">');
html = html.replace(/<link rel="icon"[^>]+>/, '<link rel="icon" href="app-icon.png" type="image/png">');
html = html.replace('</style>', `
    .auth-mark.privmsg-brand-mark { display: block; width: min(240px, 100%); height: auto; border: 0; border-radius: 0; background: transparent; box-shadow: none; object-fit: contain; }
    .identity-logo { width: min(168px, 52vw); height: auto; object-fit: contain; border-radius: 0; background: transparent; }
    .native-app-actions[hidden] { display: none; }
    .native-menu-item { display: block; width: 100%; margin-top: 7px; padding: 12px; border: 1px solid #34393d; border-radius: 12px; background: #202326; color: #e4e7e9; font: inherit; font-size: 13px; text-align: left; cursor: pointer; }
    .native-menu-item:active { background: #292d31; }
  </style>`);
if (html.includes('IMG_0630.webp') || !html.includes('privmsg-brand-mark')) throw new Error('Could not embed native app branding.');
// Native transfers finish asynchronously. Do not stage a prepared file after
// the signed-in account or destination conversation changes during its preview.
const addFilesMatch = html.match(/    async function addFiles\(fileList\) \{[\s\S]*?\n    function releaseStaged/);
if (!addFilesMatch) throw new Error('Could not guard native file staging.');
const guardedAddFiles = addFilesMatch[0]
  .replace('async function addFiles(fileList) {', 'async function addFiles(fileList, canStillAccept = () => true) {\n      if (!canStillAccept()) return;')
  .replace('if (!files.length) return;', 'if (!files.length) return;\n      const prepared = [];')
  .replace('for (const file of files) {', 'for (const file of files) {\n          if (!canStillAccept()) return;')
  .replace('            staged.push({', '            if (!canStillAccept()) return;\n            prepared.push({')
  .replace('objectUrl: imageFile ? URL.createObjectURL(previewBlob || file) : ""', 'objectUrl: ""')
  .replace('      } finally {\n        preparingFiles--;', `        if (!canStillAccept()) return;
        // Commit the whole native paste together, after every preview finishes.
        for (const item of prepared) {
          if (item.category === "image") item.objectUrl = URL.createObjectURL(item.previewBlob || item.file);
        }
        staged.push(...prepared);
        prepared.length = 0;
      } finally {
        releaseStaged(prepared);
        preparingFiles--;`);
if (!guardedAddFiles.includes('prepared.push({') || !guardedAddFiles.includes('staged.push(...prepared)')) throw new Error('Could not make native file staging atomic.');
html = html.replace(addFilesMatch[0], guardedAddFiles);
const pasteButtonHook = 'pasteButton.addEventListener("click", pasteFromClipboard);';
if (!html.includes(pasteButtonHook)) throw new Error('Could not connect native clipboard paste.');
html = html.replace(pasteButtonHook, `pasteButton.addEventListener("click", () => {
      closeAttachmentMenu();
      if (!window.PrivMsgNative?.action("pasteFiles")) pasteFromClipboard();
    });`);
html = html.replace('<script type="module">', '<script type="module">\n    import { installNativeBridge } from "./native-bridge.js";');
const hook = `
    installNativeBridge({
      getUser: () => isAllowedPasswordUser(auth.currentUser) ? auth.currentUser : null,
      getThreadID: () => window.__privmsgActiveThreadId || '',
      getMessages: () => messages,
      input: messageInput,
      addFiles: (files, isCurrent) => addFiles(files, isCurrent),
      canAcceptFiles: () => Boolean(currentUser) && !saving && audioState === 'idle' && !window.__privmsgRecorderBusy?.(),
      insertText: insertTextAtCursor,
      setReading: reading => {
        preparingFiles += reading ? 1 : -1;
        if (!preparingFiles) composerMeta.textContent = '';
        updateSendState();
      },
      projectID: firebaseConfig.projectId,
      watchAuth: callback => onAuthStateChanged(auth, callback),
      signOut: async () => {
        if (saving || preparingFiles > 0 || audioState !== 'idle' || window.__privmsgRecorderBusy?.()) {
          throw new Error('Wait for your upload or recording to finish.');
        }
        await signOut(auth);
      }
    });
`;
const end = html.indexOf('    autoSizeInput();\n    updateSendState();\n  </script>');
if (end < 0) throw new Error('Could not place the native bridge.');
html = html.slice(0, end) + hook + html.slice(end);
const packed = await fs.readFile(path.join(repo, 'enhancements.js'), 'utf8');
const match = packed.match(/const packed = "([^"]+)"/);
if (!match) throw new Error('Could not unpack conversation enhancements.');
let enhancements = gunzipSync(Buffer.from(match[1], 'base64')).toString('utf8');
enhancements += '\nwindow.__privmsgRecorderBusy = () => recorderBusy || recorder != null;\n';
enhancements = enhancements.replaceAll('window.__privmsgActiveThreadId = activeThreadId || null;', 'window.__privmsgActiveThreadId = activeThreadId || null;\n  window.dispatchEvent(new Event("privmsg:thread"));');
enhancements = enhancements.replace('function renderRecordings() {', 'function renderRecordings() {\n  window.dispatchEvent(new CustomEvent("privmsg:recordings", { detail: { recordings } }));');
enhancements = enhancements.replace('document.body.append(backdrop, drawer);', 'document.body.append(backdrop, drawer);\n  window.dispatchEvent(new Event("privmsg:drawer"));');
if (!enhancements.includes('privmsg:recordings') || !enhancements.includes('privmsg:thread') || !enhancements.includes('privmsg:drawer')) throw new Error('Could not install conversation notifications.');
await fs.mkdir(resources, {recursive:true});
await fs.writeFile(path.join(resources, 'index.html'), html);
await fs.writeFile(path.join(resources, 'enhancements.js'), enhancements);
await fs.copyFile(path.join(repo, 'clipboard.js'), path.join(resources, 'clipboard.js'));
await fs.copyFile(path.join(ios, 'PrivMsg/Assets.xcassets/BrandLogo.imageset/BrandLogo.png'), path.join(resources, 'app-icon.png'));
const manifest = {
  webBaseCommit: 'beafc9bd5bf2f49214cca0a1195632035ce70c45',
  snapshotFromCommit: 'd8f27753123060f777b0827d99bd5383158ec3dc',
  files: {}
};
for (const name of ['index.html', 'enhancements.js', 'clipboard.js', 'native-bridge.js', 'native-paste.js', 'app-icon.png']) {
  manifest.files[name] = createHash('sha256').update(await fs.readFile(path.join(resources,name))).digest('hex');
}
await fs.writeFile(path.join(ios, 'web-bundle.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log('Bundled PrivMsg web UI with clipboard uploads and native file bridge.');
