// The bundled app installs this module inside PrivMsg's existing Firebase module.
// Only attachment metadata crosses the push bridge. Tokens are fetched on demand.
export function installNativeBridge({ getUser, getMessages, projectID, watchAuth, signOut }) {
  const handler = window.webkit?.messageHandlers?.privmsg;
  if (!handler) return;
  let recordings = [];
  let scheduled = false;

  function dateKey(value) {
    const millis = value?.toMillis ? value.toMillis() : (value?.seconds ? value.seconds * 1000 : Number(value) || Date.now());
    const date = new Date(millis);
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
  }

  function snapshot() {
    scheduled = false;
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
      recordings = [];
      snapshot();
    }
  });
  window.addEventListener('privmsg:messages', scheduleSnapshot);
  window.addEventListener('privmsg:thread', scheduleSnapshot);
  window.addEventListener('privmsg:recordings', event => {
    recordings = Array.isArray(event.detail?.recordings) ? event.detail.recordings : [];
    scheduleSnapshot();
  });
  watchAuth(scheduleSnapshot);
  scheduleSnapshot();
}
