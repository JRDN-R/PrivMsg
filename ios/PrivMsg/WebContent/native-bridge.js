// The bundled app installs this module inside PrivMsg's existing Firebase module.
// Only attachment metadata crosses the push bridge. Tokens are fetched on demand.
import { createNativePasteReceiver } from './native-paste.js';

export function installNativeBridge({ getUser, getThreadID, getMessages, projectID, watchAuth, signOut,
  input, addFiles, canAcceptFiles = () => true, insertText, setReading }) {
  const handler = window.webkit?.messageHandlers?.privmsg;
  if (typeof handler?.postMessage !== 'function') return;
  let recordings = [];
  let scheduled = false;
  const pasteReceiver = createNativePasteReceiver({getUser, getThreadID, addFiles, canAcceptFiles, insertText, setReading});
  const menuActions = [
    ['openFiles', 'Files'],
    ['reload', 'Reload'],
    ['clearDownloads', 'Clear downloaded copies'],
    ['signOut', 'Sign out']
  ];
  const allowedActions = new Set([...menuActions.map(([action]) => action), 'pasteFiles']);

  function action(name, fallbackText) {
    if (typeof name !== 'string' || !allowedActions.has(name) || !getUser()) return false;
    const message = {type: 'action', action: name};
    if (name === 'pasteFiles' && fallbackText !== undefined) {
      if (fallbackText !== null && (typeof fallbackText !== 'string' || fallbackText.length > 1_000_000)) return false;
      message.fallbackText = fallbackText;
    }
    window.document?.querySelector('.thread-drawer .drawer-close')?.click();
    handler.postMessage(message);
    return true;
  }

  // This listener follows clipboard.js. Files already exposed to WebKit keep
  // that normal path; native item providers cover files WebKit exposes as text.
  input?.addEventListener('paste', event => {
    if (event.defaultPrevented || event.clipboardData?.files?.length || !getUser() || !canAcceptFiles()) return;
    let fallbackText = null;
    try {
      const text = event.clipboardData?.getData('text/plain');
      if (typeof text === 'string') fallbackText = text;
    } catch { /* The explicit native paste can read the text fallback. */ }
    if (action('pasteFiles', fallbackText)) event.preventDefault();
  });

  function updateMenu() {
    const document = window.document;
    const drawer = document?.querySelector('.thread-drawer .drawer-scroll');
    if (!drawer) return;
    let section = document.getElementById('nativeAppActions');
    if (!section) {
      section = document.createElement('section');
      section.id = 'nativeAppActions';
      section.className = 'drawer-section native-app-actions';
      section.setAttribute('aria-label', 'App actions');
      for (const [name, label] of menuActions) {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'native-menu-item';
        button.textContent = label;
        button.addEventListener('click', () => action(name));
        section.append(button);
      }
      drawer.append(section);
    }
    section.hidden = !getUser();
  }

  function dateKey(value) {
    const millis = value?.toMillis ? value.toMillis() : (value?.seconds ? value.seconds * 1000 : Number(value) || Date.now());
    const date = new Date(millis);
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
  }

  function snapshot() {
    scheduled = false;
    updateMenu();
    const user = getUser();
    const threadID = window.__privmsgActiveThreadId || '';
    const attachments = [];
    const seen = new Set();
    let unavailable = 0;
    function append(meta, owner, messageId) {
      if (!owner || owner !== user.uid) return;
      if (!meta?.key || !Number.isSafeInteger(Number(meta.chunks)) || Number(meta.chunks) < 1 || !Number.isSafeInteger(Number(meta.size)) || Number(meta.size) < 1) {
        unavailable++;
        return;
      }
      const id = `${messageId}:${meta.key}`;
      if (seen.has(id)) return;
      seen.add(id);
      attachments.push({
        id, key: String(meta.key), messageId, owner,
        name: String(meta.name || 'Attachment'), mimeType: String(meta.type || 'application/octet-stream'),
        size: Number(meta.size), chunks: Number(meta.chunks), encoding: meta.encoding || null
      });
    }
    if (user) {
      for (const message of getMessages()) {
        const effectiveThread = message.threadId || `legacy-${dateKey(message.createdAt)}`;
        if (threadID && effectiveThread !== threadID) continue;
        for (const meta of message.attachments || message.images || []) append(meta, message.owner, message.id);
      }
      for (const recording of recordings) {
        if (threadID && recording.threadId !== threadID) continue;
        append(recording, recording.owner, recording.id);
      }
    }
    handler.postMessage({ type: 'snapshot', signedIn: Boolean(user), uid: user?.uid || '', threadID, attachments, unavailable });
  }

  function scheduleSnapshot() {
    if (scheduled) return;
    scheduled = true;
    // Let the conversation enhancement apply its active-thread changes first.
    setTimeout(snapshot, 0);
  }

  window.PrivMsgNative = Object.freeze({
    ...pasteReceiver,
    action,
    snapshot,
    async session(forceRefresh = false) {
      const user = getUser();
      if (!user) throw new Error('Sign in to PrivMsg before opening files.');
      const token = await user.getIdToken(forceRefresh);
      if (getUser()?.uid !== user.uid) throw new Error('The signed-in account changed.');
      return { uid: user.uid, token, projectID };
    },
    async signOut() {
      await signOut();
      pasteReceiver.cancelPaste('');
      recordings = [];
      snapshot();
    }
  });
  window.addEventListener('privmsg:messages', scheduleSnapshot);
  window.addEventListener('privmsg:drawer', updateMenu);
  window.addEventListener('privmsg:thread', scheduleSnapshot);
  window.addEventListener('privmsg:recordings', event => {
    recordings = Array.isArray(event.detail?.recordings) ? event.detail.recordings : [];
    scheduleSnapshot();
  });
  watchAuth(() => {
    pasteReceiver.cancelPaste('');
    scheduleSnapshot();
  });
  scheduleSnapshot();
}
