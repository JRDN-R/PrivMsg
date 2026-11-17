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
  '<img class="auth-mark privmsg-brand-mark" src="app-icon.png" alt="" width="84" height="84">');
html = html.replace(/<img\s+class="identity-logo"[\s\S]*?>/,
  '<img class="identity-logo" src="app-icon.png" alt="" width="36" height="36"><span class="identity-wordmark">PrivMsg</span>');
html = html.replace(/<link rel="icon"[^>]+>/, '<link rel="icon" href="app-icon.png" type="image/png">');
html = html.replace('</style>', `
    .auth-mark.privmsg-brand-mark { display: block; width: 84px; height: 84px; border: 0; border-radius: 21px; background: #000; box-shadow: none; object-fit: contain; }
    .identity { gap: 10px; }
    .identity-logo { width: 36px; height: 36px; flex: 0 0 36px; object-fit: contain; border-radius: 9px; }
    .identity-wordmark { font-size: 18px; font-weight: 680; letter-spacing: -.03em; }
  </style>`);
if (html.includes('IMG_0630.webp') || !html.includes('privmsg-brand-mark')) throw new Error('Could not embed native app branding.');
html = html.replace('<script type="module">', '<script type="module">\n    import { installNativeBridge } from "./native-bridge.js";');
const hook = `
    installNativeBridge({
      getUser: () => isAllowedPasswordUser(auth.currentUser) ? auth.currentUser : null,
      getMessages: () => messages,
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
if (!enhancements.includes('privmsg:recordings') || !enhancements.includes('privmsg:thread')) throw new Error('Could not install conversation notifications.');
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
for (const name of ['index.html', 'enhancements.js', 'clipboard.js', 'native-bridge.js', 'app-icon.png']) {
  manifest.files[name] = createHash('sha256').update(await fs.readFile(path.join(resources,name))).digest('hex');
}
await fs.writeFile(path.join(ios, 'web-bundle.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log('Bundled PrivMsg web UI with clipboard uploads and native file bridge.');
