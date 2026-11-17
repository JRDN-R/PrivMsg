// Receives bounded file chunks from an explicit iOS paste action. These become
// ordinary File objects in the existing composer, never messages or uploads here.
export function createNativePasteReceiver({
  getUser, getThreadID = () => '', addFiles = async () => { throw new Error('File input is unavailable.'); },
  canAcceptFiles = () => true, insertText = () => {}, setReading = () => {}
}) {
  const MAX_BYTES = 100 * 1024 * 1024;
  const CHUNK_BYTES = 256 * 1024;
  let active = null;

  const matches = batch => !batch.cancelled && getUser()?.uid === batch.uid &&
    String(getThreadID() || '') === batch.threadID;
  const validID = value => typeof value === 'string' && value.length > 0 && value.length <= 128;

  function cancelPaste(id) {
    if (!active || (id && active.id !== id)) return false;
    const batch = active;
    active = null;
    batch.cancelled = true;
    clearTimeout(batch.timer);
    batch.files.clear();
    setReading(false);
    return true;
  }

  function touch(batch) {
    clearTimeout(batch.timer);
    batch.timer = setTimeout(() => cancelPaste(batch.id), 90_000);
  }

  function requireBatch(id) {
    if (!active || active.id !== id) throw new Error('That file paste is no longer active.');
    if (!matches(active)) {
      cancelPaste(id);
      throw new Error('The account or conversation changed. Paste the files again.');
    }
    return active;
  }

  function preparePaste(payload) {
    if (active) throw new Error('Wait for the current file paste to finish.');
    if (!payload || !validID(payload.id) || !validID(payload.uid) ||
        typeof payload.threadID !== 'string' || payload.threadID.length > 512) {
      throw new Error('The copied file information is invalid.');
    }
    const batch = {id: payload.id, uid: payload.uid, threadID: payload.threadID,
      files: new Map(), cancelled: false, committing: false, prepared: false, timer: null};
    if (!matches(batch) || !canAcceptFiles()) throw new Error('Sign in and wait for the current upload before pasting files.');
    active = batch;
    touch(batch);
    setReading(true);
    return true;
  }

  function beginPaste(payload) {
    const batch = requireBatch(payload?.id);
    if (batch.prepared || payload.uid !== batch.uid || payload.threadID !== batch.threadID ||
        !Array.isArray(payload.files) || !payload.files.length || payload.files.length > 20) {
      cancelPaste(batch.id);
      throw new Error('The copied file information is invalid.');
    }
    let total = 0;
    for (const file of payload.files) {
      if (!file || !validID(file.id) || batch.files.has(file.id) ||
          typeof file.name !== 'string' || !file.name || file.name.length > 1024 ||
          /[\\/\u0000]/.test(file.name) || typeof file.type !== 'string' || file.type.length > 256 ||
          !Number.isSafeInteger(file.size) || file.size <= 0 || (total += file.size) > MAX_BYTES) {
        cancelPaste(batch.id);
        throw new Error('Paste up to 20 files totaling 100 MB. Use Upload files for larger items.');
      }
      batch.files.set(file.id, {...file, parts: [], received: 0, nextIndex: 0});
    }
    batch.prepared = true;
    touch(batch);
    return true;
  }

  function keepPasteAlive(id) {
    const batch = requireBatch(id);
    touch(batch);
    return true;
  }

  function appendPaste(payload) {
    const batch = requireBatch(payload?.id);
    const file = batch.files.get(payload?.fileID);
    if (!batch.prepared || batch.committing || !file || payload.index !== file.nextIndex ||
        typeof payload.base64 !== 'string' || !payload.base64.length ||
        payload.base64.length > 4 * Math.ceil(CHUNK_BYTES / 3) ||
        payload.base64.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(payload.base64)) {
      cancelPaste(batch.id);
      throw new Error('A copied file chunk was invalid or out of order.');
    }
    const binary = atob(payload.base64);
    if (!binary.length || binary.length > CHUNK_BYTES || file.received + binary.length > file.size) {
      cancelPaste(batch.id);
      throw new Error('A copied file has an unexpected size.');
    }
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
    file.parts.push(bytes);
    file.received += bytes.length;
    file.nextIndex++;
    touch(batch);
    return true;
  }

  async function commitPaste(id) {
    const batch = requireBatch(id);
    if (!batch.prepared || batch.committing || [...batch.files.values()].some(file => file.received !== file.size)) {
      cancelPaste(id);
      throw new Error('The copied files are incomplete. Paste them again.');
    }
    batch.committing = true;
    clearTimeout(batch.timer);
    try {
      const files = [...batch.files.values()].map(file => new File(file.parts, file.name, {
        type: file.type || 'application/octet-stream',
        lastModified: Number.isFinite(file.lastModified) && file.lastModified > 0 ? file.lastModified : Date.now()
      }));
      await addFiles(files, () => matches(batch));
      if (!matches(batch)) throw new Error('The account or conversation changed. Paste the files again.');
      return true;
    } finally {
      cancelPaste(id);
    }
  }

  function insertPastedText(payload) {
    if (!payload || typeof payload.text !== 'string' || payload.text.length > 1_000_000 ||
        getUser()?.uid !== payload.uid || String(getThreadID() || '') !== payload.threadID || !canAcceptFiles()) {
      throw new Error('The account or conversation changed, or the composer is busy.');
    }
    insertText(payload.text);
    return true;
  }

  return Object.freeze({preparePaste, keepPasteAlive, beginPaste, appendPaste, commitPaste, cancelPaste, insertPastedText});
}
