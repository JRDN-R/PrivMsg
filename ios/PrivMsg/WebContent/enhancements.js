import { getApp } from "https://www.gstatic.com/firebasejs/12.16.0/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/12.16.0/firebase-auth.js";
import {
  getFirestore, collection, doc, setDoc, addDoc, getDoc, getDocs, deleteDoc,
  query, where, onSnapshot, serverTimestamp
} from "https://www.gstatic.com/firebasejs/12.16.0/firebase-firestore.js";
import { getFunctions, httpsCallable } from "https://www.gstatic.com/firebasejs/12.16.0/firebase-functions.js";

const app = getApp();
const auth = getAuth(app);
const db = getFirestore(app);
const functions = getFunctions(app, "us-central1");
const transcribeAudioCallable = httpsCallable(functions, "transcribeAudio", { timeout: 540000 });

const COLL = "drops";
const CHUNK_BYTES = 512 * 1024;
const CHUNK_ENCODING = "base64-chunk-v1";
const MAX_AUDIO_BYTES = 20 * 1024 * 1024;
const AUDIO_BITRATE = 64000;
const RECORDING_CACHE = new Map();
const STOP_WORDS = new Set([
  "about","after","again","also","and","are","because","been","before","being","between","but","can","could","did","does","doing","don","for","from","get","getting","got","had","has","have","here","how","into","is","it","its","just","like","more","most","not","now","of","on","one","only","or","our","out","over","really","said","same","should","some","that","the","their","them","then","there","these","they","this","those","through","to","too","was","we","were","what","when","where","which","who","will","with","would","you","your"
]);

let user = null;
let messages = [];
let threadDocs = [];
let recordings = [];
let activeThreadId = localStorage.getItem("privmsg.activeThread") || "";
let recorder = null;
let recorderStream = null;
let recorderChunks = [];
let recorderBytes = 0;
let recorderStartedAt = 0;
let recorderTimer = null;
let recorderAction = "save";
let recorderBusy = false;
let unsubscribeThreads = null;
let unsubscribeRecordings = null;
let toastTimer = null;

const waitFor = selector => new Promise(resolve => {
  const found = document.querySelector(selector);
  if (found) return resolve(found);
  const observer = new MutationObserver(() => {
    const element = document.querySelector(selector);
    if (!element) return;
    observer.disconnect();
    resolve(element);
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
});

const [headerInner, micButton, messageInput, messageList, emptyState] = await Promise.all([
  waitFor(".header-inner"), waitFor("#micButton"), waitFor("#messageInput"),
  waitFor("#messageList"), waitFor("#emptyState")
]);

injectStyles();
const ui = buildInterface();
installRecorder();
installThreadEvents();

onAuthStateChanged(auth, current => {
  user = current || null;
  if (!user) {
    stopSnapshots();
    return;
  }
  startSnapshots();
});

window.addEventListener("privmsg:messages", event => {
  messages = Array.isArray(event.detail?.messages) ? event.detail.messages : [];
  refreshAll();
});

window.addEventListener("beforeunload", () => {
  stopRecorderTimer();
  stopRecorderTracks();
  for (const url of RECORDING_CACHE.values()) URL.revokeObjectURL(url);
});

function injectStyles() {
  const style = document.createElement("style");
  style.textContent = `
    .header-actions{display:flex;align-items:center;gap:10px;flex:0 0 auto}
    .thread-menu-button{width:38px;height:38px;padding:0;display:grid;place-items:center;border:1px solid #353a3f;border-radius:12px;background:#202326;color:#dce1e5;cursor:pointer}
    .thread-menu-button:hover{background:#292d31}.thread-menu-button svg{width:19px;height:19px}
    .thread-backdrop{position:fixed;inset:0;z-index:80;background:rgba(0,0,0,.42);backdrop-filter:blur(3px);-webkit-backdrop-filter:blur(3px);opacity:0;pointer-events:none;transition:opacity .18s}
    .thread-backdrop.open{opacity:1;pointer-events:auto}
    .thread-drawer{position:fixed;inset:0 0 0 auto;z-index:81;width:min(390px,92vw);display:flex;flex-direction:column;border-left:1px solid #34383c;background:rgba(22,24,26,.985);box-shadow:-20px 0 55px rgba(0,0,0,.38);transform:translateX(102%);transition:transform .2s ease-out}
    .thread-drawer.open{transform:translateX(0)}
    .drawer-head{padding:max(18px,env(safe-area-inset-top)) 18px 14px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #303438}
    .drawer-head h2{margin:0;font-size:17px}.drawer-close{width:34px;height:34px;padding:0;display:grid;place-items:center;border:0;border-radius:10px;background:transparent;color:#b8bec3;cursor:pointer}.drawer-close:hover{background:#292d31;color:white}
    .drawer-scroll{min-height:0;flex:1;overflow:auto;padding:14px 14px 20px}
    .drawer-section{margin-bottom:22px}.drawer-section:last-child{margin-bottom:0}.drawer-section-head{margin:0 4px 9px;display:flex;align-items:center;justify-content:space-between;color:#8f969c;font-size:10px;font-weight:700;letter-spacing:.09em;text-transform:uppercase}
    .new-thread{padding:5px 8px;border:1px solid #3d4348;border-radius:8px;background:#24282b;color:#e4e7e9;font-size:10px;letter-spacing:0;text-transform:none;cursor:pointer}
    .thread-list,.recording-list{display:grid;gap:7px}.thread-entry{display:flex;align-items:stretch;border:1px solid #34393d;border-radius:13px;background:#202326;overflow:hidden}.thread-entry.active{border-color:#68737c;background:#292d31}.thread-select{min-width:0;flex:1;padding:11px 12px;border:0;background:transparent;color:inherit;text-align:left;cursor:pointer}.thread-date{display:block;color:#8f969c;font-size:9.5px;margin-bottom:4px}.thread-summary{display:block;overflow:hidden;color:#f0f2f3;font-size:13px;font-weight:620;text-overflow:ellipsis;white-space:nowrap}.thread-count{display:block;margin-top:4px;color:#737a80;font-size:9.5px}.thread-delete{width:42px;flex:0 0 auto;border:0;border-left:1px solid #34393d;background:transparent;color:#8c9297;cursor:pointer}.thread-delete:hover{background:rgba(223,123,118,.1);color:#df7b76}
    .recording-entry{padding:10px;border:1px solid #34393d;border-radius:13px;background:#202326}.recording-top{display:flex;align-items:center;gap:10px}.recording-play{width:36px;height:36px;flex:0 0 auto;padding:0;display:grid;place-items:center;border:1px solid #41474c;border-radius:50%;background:#2a2e31;color:#edf0f2;cursor:pointer}.recording-play svg{width:15px;height:15px}.recording-info{min-width:0;flex:1}.recording-name{display:block;overflow:hidden;color:#eef0f2;font-size:12px;font-weight:620;text-overflow:ellipsis;white-space:nowrap}.recording-meta{display:block;margin-top:3px;color:#858c92;font-size:9.5px}.recording-delete{width:31px;height:31px;padding:0;display:grid;place-items:center;border:0;border-radius:9px;background:transparent;color:#858c92;cursor:pointer}.recording-delete:hover{background:rgba(223,123,118,.1);color:#df7b76}.recording-player{width:100%;height:34px;margin-top:9px}.recording-download{display:inline-block;margin-top:7px;color:#bdc7ce;font-size:10px;text-decoration:none}.drawer-empty{padding:18px 10px;border:1px dashed #34393d;border-radius:12px;color:#747b81;font-size:11px;text-align:center}
    .recording-cancel{width:42px;height:42px;padding:0;display:none;place-items:center;border:1px solid #714b49;border-radius:50%;background:#392827;color:#efaaa5;cursor:pointer}.recording-cancel.visible{display:grid}.recording-cancel svg{width:18px;height:18px}.mic-button.enhancement-recording{background:#df7b76!important;color:#18191b!important;box-shadow:0 0 0 5px rgba(223,123,118,.13)}
    .recorder-status{display:none;align-items:center;gap:7px;margin:0 7px 7px;padding:7px 10px;border-radius:10px;background:rgba(223,123,118,.09);color:#e9a09b;font-size:10.5px}.recorder-status.visible{display:flex}.recorder-pulse{width:7px;height:7px;border-radius:50%;background:#df7b76;animation:recPulse 1.1s ease-in-out infinite}@keyframes recPulse{50%{opacity:.25}}
    @media(max-width:620px){.connection span{display:none}.header-actions{gap:7px}.thread-menu-button{width:36px;height:36px}.thread-drawer{width:94vw}}
  `;
  document.head.append(style);
}

function buildInterface() {
  const connection = headerInner.querySelector(".connection");
  const actions = document.createElement("div");
  actions.className = "header-actions";
  if (connection) actions.append(connection);

  const menu = document.createElement("button");
  menu.type = "button";
  menu.className = "thread-menu-button";
  menu.setAttribute("aria-label", "Open conversations and recordings");
  menu.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M5 7h14M5 12h14M5 17h14"/></svg>';
  actions.append(menu);
  headerInner.append(actions);

  const backdrop = document.createElement("div");
  backdrop.className = "thread-backdrop";
  const drawer = document.createElement("aside");
  drawer.className = "thread-drawer";
  drawer.setAttribute("aria-label", "Conversations and recorded files");
  drawer.innerHTML = `
    <div class="drawer-head"><h2>Conversations</h2><button class="drawer-close" type="button" aria-label="Close panel">✕</button></div>
    <div class="drawer-scroll">
      <section class="drawer-section">
        <div class="drawer-section-head"><span>Threads</span><button class="new-thread" type="button">New conversation</button></div>
        <div class="thread-list"></div>
      </section>
      <section class="drawer-section">
        <div class="drawer-section-head"><span>Recorded files</span></div>
        <div class="recording-list"></div>
      </section>
    </div>`;
  document.body.append(backdrop, drawer);
  window.dispatchEvent(new Event("privmsg:drawer"));

  const close = () => {
    backdrop.classList.remove("open");
    drawer.classList.remove("open");
  };
  menu.addEventListener("click", () => {
    backdrop.classList.add("open");
    drawer.classList.add("open");
  });
  backdrop.addEventListener("click", close);
  drawer.querySelector(".drawer-close").addEventListener("click", close);
  drawer.querySelector(".new-thread").addEventListener("click", createManualThread);

  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.className = "recording-cancel";
  cancel.setAttribute("aria-label", "Cancel and discard recording");
  cancel.title = "Cancel recording";
  cancel.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round"><path d="m6 6 12 12M18 6 6 18"/></svg>';
  micButton.insertAdjacentElement("afterend", cancel);

  const status = document.createElement("div");
  status.className = "recorder-status";
  status.innerHTML = '<span class="recorder-pulse"></span><span class="recorder-status-text">Recording 0:00</span>';
  const composeRow = micButton.closest(".compose-row");
  composeRow?.insertAdjacentElement("beforebegin", status);

  return {
    drawer, backdrop, threadList: drawer.querySelector(".thread-list"),
    recordingList: drawer.querySelector(".recording-list"), cancel,
    recorderStatus: status, recorderStatusText: status.querySelector(".recorder-status-text")
  };
}

function installRecorder() {
  micButton.addEventListener("click", event => {
    event.preventDefault();
    event.stopImmediatePropagation();
    if (recorderBusy) return;
    if (recorder?.state === "recording") stopRecordingAndSave();
    else startRecording();
  }, true);

  ui.cancel.addEventListener("click", event => {
    event.preventDefault();
    event.stopPropagation();
    cancelRecording();
  });
}

async function startRecording() {
  if (!user) return showToast("Sign in before recording.", true);
  if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
    return showToast("Audio recording is not supported in this browser.", true);
  }

  recorderBusy = true;
  try {
    recorderStream = await openMicrophone();
    const preferred = preferredAudioType();
    const options = { audioBitsPerSecond: AUDIO_BITRATE };
    if (preferred.mime) options.mimeType = preferred.mime;
    try { recorder = new MediaRecorder(recorderStream, options); }
    catch { recorder = new MediaRecorder(recorderStream); }

    recorderChunks = [];
    recorderBytes = 0;
    recorderAction = "save";
    recorder.addEventListener("dataavailable", event => {
      if (!event.data?.size) return;
      recorderChunks.push(event.data);
      recorderBytes += event.data.size;
      if (recorderBytes >= MAX_AUDIO_BYTES && recorder?.state === "recording") {
        showToast("Recording limit reached. Saving and transcribing now.");
        stopRecordingAndSave();
      }
    });
    recorder.addEventListener("error", event => {
      console.error(event.error || event);
      showToast("The audio recording failed.", true);
    });
    recorder.addEventListener("stop", finishRecording, { once: true });
    recorder.start(500);
    recorderStartedAt = Date.now();
    updateRecordingUI();
    recorderTimer = setInterval(updateRecordingUI, 250);
    setRecordingVisual(true);
  } catch (error) {
    console.error(error);
    stopRecorderTracks();
    showToast(friendlyMicrophoneError(error), true);
  } finally {
    recorderBusy = false;
  }
}

function stopRecordingAndSave() {
  if (!recorder || recorder.state !== "recording") return;
  recorderAction = "save";
  stopRecorderTimer();
  recorder.stop();
  setRecordingVisual(false, "Saving recording…");
}

function cancelRecording() {
  if (!recorder || recorder.state !== "recording") return;
  recorderAction = "discard";
  stopRecorderTimer();
  recorder.stop();
  setRecordingVisual(false);
  showToast("Recording discarded");
}

async function finishRecording() {
  const currentRecorder = recorder;
  const chunks = recorderChunks;
  const action = recorderAction;
  const durationMs = Math.max(0, Date.now() - recorderStartedAt);
  recorder = null;
  recorderChunks = [];
  recorderBytes = 0;
  stopRecorderTracks();
  setRecordingVisual(false);

  if (action === "discard" || !chunks.length) return;
  const mimeType = currentRecorder?.mimeType || chunks[0]?.type || "audio/webm";
  const audio = new Blob(chunks, { type: mimeType });
  if (!audio.size) return showToast("No audio was captured.", true);

  recorderBusy = true;
  micButton.disabled = true;
  try {
    await saveRecording(audio, durationMs);
    showToast("Recording saved");
  } catch (error) {
    console.error(error);
    showToast("The recording could not be saved, but transcription will still be attempted.", true);
  }

  try {
    ui.recorderStatus.classList.add("visible");
    ui.recorderStatusText.textContent = "Transcribing saved recording…";
    const audioBase64 = await blobToBase64(audio);
    const response = await transcribeAudioCallable({ audioBase64, mimeType });
    const transcript = String(response?.data?.text || "").trim();
    if (!transcript) throw new Error("The transcription service returned an empty transcript.");
    appendTranscript(transcript);
  } catch (error) {
    console.error(error);
    showToast("Recording saved, but transcription failed.", true);
  } finally {
    recorderBusy = false;
    micButton.disabled = false;
    ui.recorderStatus.classList.remove("visible");
  }
}

async function saveRecording(audio, durationMs) {
  const key = crypto.randomUUID();
  const chunkCount = Math.ceil(audio.size / CHUNK_BYTES);
  let completed = 0;
  try {
    await mapConcurrency(chunkCount, 4, async index => {
      const start = index * CHUNK_BYTES;
      const bytes = new Uint8Array(await audio.slice(start, start + CHUNK_BYTES).arrayBuffer());
      await setDoc(doc(db, COLL, `chunk_${key}_${index}`), {
        kind: "chunk", key, index, data: bytesToBase64(bytes), encoding: CHUNK_ENCODING, owner: user.uid
      });
      completed++;
      ui.recorderStatus.classList.add("visible");
      ui.recorderStatusText.textContent = `Saving recording ${Math.round((completed / chunkCount) * 100)}%`;
    });
    const extension = extensionForAudio(audio.type);
    await addDoc(collection(db, COLL), {
      kind: "recording",
      owner: user.uid,
      threadId: activeThreadId || window.__privmsgActiveThreadId || null,
      name: `Recording ${new Date().toLocaleString().replace(/[/:]/g, "-")}.${extension}`,
      type: audio.type || "audio/webm",
      size: audio.size,
      durationMs,
      key,
      chunks: chunkCount,
      encoding: CHUNK_ENCODING,
      createdAt: serverTimestamp()
    });
  } catch (error) {
    await Promise.allSettled(Array.from({ length: chunkCount }, (_, index) => deleteDoc(doc(db, COLL, `chunk_${key}_${index}`))));
    throw error;
  }
}

function setRecordingVisual(recording, statusText = "") {
  micButton.classList.toggle("enhancement-recording", recording);
  ui.cancel.classList.toggle("visible", recording);
  micButton.innerHTML = recording
    ? '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="6.5" y="6.5" width="11" height="11" rx="2.2"/></svg>'
    : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21M9 21h6"/></svg>';
  micButton.setAttribute("aria-label", recording ? "Stop and save recording" : "Start voice recording");
  micButton.title = recording ? "Stop and save recording" : "Voice recording";
  if (recording || statusText) {
    ui.recorderStatus.classList.add("visible");
    if (statusText) ui.recorderStatusText.textContent = statusText;
  } else if (!recorderBusy) {
    ui.recorderStatus.classList.remove("visible");
  }
}

function updateRecordingUI() {
  const elapsed = Math.max(0, Date.now() - recorderStartedAt);
  const seconds = Math.floor(elapsed / 1000);
  const text = `Recording ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
  ui.recorderStatusText.textContent = text;
  micButton.title = `${text} · tap to stop and save`;
  micButton.setAttribute("aria-label", `${text}, stop and save`);
}

function stopRecorderTimer() { clearInterval(recorderTimer); recorderTimer = null; }
function stopRecorderTracks() {
  if (recorderStream) for (const track of recorderStream.getTracks()) track.stop();
  recorderStream = null;
}

async function openMicrophone() {
  const detailed = { video: false, audio: { channelCount: { ideal: 1 }, sampleRate: { ideal: 24000 }, echoCancellation: true, noiseSuppression: true, autoGainControl: true } };
  try { return await navigator.mediaDevices.getUserMedia(detailed); }
  catch (error) {
    if (error?.name === "OverconstrainedError") return navigator.mediaDevices.getUserMedia({ audio: true, video: false });
    throw error;
  }
}

function preferredAudioType() {
  const candidates = [
    { mime: "audio/webm;codecs=opus", extension: "webm" },
    { mime: "audio/mp4;codecs=mp4a.40.2", extension: "m4a" },
    { mime: "audio/mp4", extension: "m4a" },
    { mime: "audio/webm", extension: "webm" }
  ];
  return candidates.find(item => MediaRecorder.isTypeSupported(item.mime)) || { mime: "", extension: "webm" };
}

function friendlyMicrophoneError(error) {
  if (["NotAllowedError", "SecurityError"].includes(error?.name)) return "Microphone access was blocked. Allow it in the browser settings and try again.";
  if (error?.name === "NotFoundError") return "No microphone was found.";
  if (error?.name === "NotReadableError") return "The microphone is already in use by another app.";
  return "Could not start the microphone.";
}

function appendTranscript(text) {
  const separator = messageInput.value && !/\s$/.test(messageInput.value) ? " " : "";
  messageInput.value += separator + text;
  messageInput.dispatchEvent(new Event("input", { bubbles: true }));
  messageInput.focus();
  messageInput.setSelectionRange(messageInput.value.length, messageInput.value.length);
}

function installThreadEvents() {
  document.addEventListener("keydown", event => {
    if (event.key === "Escape") {
      ui.drawer.classList.remove("open");
      ui.backdrop.classList.remove("open");
    }
  });
}

function startSnapshots() {
  stopSnapshots();
  unsubscribeThreads = onSnapshot(query(collection(db, COLL), where("kind", "==", "thread")), snapshot => {
    threadDocs = snapshot.docs.map(item => ({ id: item.id, ...item.data() })).filter(item => !item.owner || item.owner === user.uid);
    ensureDailyThread().then(refreshAll).catch(error => console.error(error));
  }, error => console.error("Thread list failed", error));
  unsubscribeRecordings = onSnapshot(query(collection(db, COLL), where("kind", "==", "recording")), snapshot => {
    recordings = snapshot.docs.map(item => ({ id: item.id, ...item.data() })).filter(item => !item.owner || item.owner === user.uid);
    recordings.sort((a, b) => toMillis(b.createdAt) - toMillis(a.createdAt));
    renderRecordings();
  }, error => console.error("Recording list failed", error));
}

function stopSnapshots() {
  if (unsubscribeThreads) unsubscribeThreads();
  if (unsubscribeRecordings) unsubscribeRecordings();
  unsubscribeThreads = unsubscribeRecordings = null;
}

async function ensureDailyThread() {
  if (!user) return;
  const today = localDateKey(new Date());
  const existing = allThreads().find(item => item.dateKey === today && item.daily);
  if (existing) {
    if (!activeThreadId) setActiveThread(existing.id);
    return;
  }
  const id = `daily-${today}`;
  const reference = doc(db, COLL, `thread_${id}`);
  const snapshot = await getDoc(reference);
  if (!snapshot.exists()) {
    await setDoc(reference, { kind: "thread", id, owner: user.uid, dateKey: today, daily: true, createdAt: serverTimestamp() });
  }
  if (!activeThreadId) setActiveThread(id);
}

async function createManualThread() {
  if (!user) return;
  const id = `thread-${Date.now()}-${crypto.randomUUID().slice(0, 6)}`;
  const now = new Date();
  await setDoc(doc(db, COLL, `thread_${id}`), {
    kind: "thread", id, owner: user.uid, dateKey: localDateKey(now), daily: false, createdAt: serverTimestamp()
  });
  setActiveThread(id);
}

function allThreads() {
  const map = new Map();
  for (const item of threadDocs) {
    const id = item.id?.startsWith("thread_") ? (item.id || "").slice(7) : (item.id || item.threadId);
    if (id) map.set(id, { ...item, id });
  }
  for (const message of messages) {
    const id = effectiveThreadId(message);
    if (!map.has(id)) map.set(id, { id, dateKey: messageDateKey(message), daily: id.startsWith("legacy-") });
  }
  for (const recording of recordings) {
    if (recording.threadId && !map.has(recording.threadId)) map.set(recording.threadId, { id: recording.threadId, dateKey: localDateKey(new Date(toMillis(recording.createdAt))) });
  }
  return [...map.values()].sort((a, b) => threadSortTime(b) - threadSortTime(a));
}

function refreshAll() {
  const threads = allThreads();
  if (activeThreadId && !threads.some(item => item.id === activeThreadId)) activeThreadId = "";
  if (!activeThreadId && threads.length) setActiveThread(threads[0].id, false);
  window.__privmsgActiveThreadId = activeThreadId || null;
  window.dispatchEvent(new Event("privmsg:thread"));
  renderThreads();
  filterMessages();
  renderRecordings();
}

function setActiveThread(id, refresh = true) {
  activeThreadId = id || "";
  window.__privmsgActiveThreadId = activeThreadId || null;
  window.dispatchEvent(new Event("privmsg:thread"));
  if (activeThreadId) localStorage.setItem("privmsg.activeThread", activeThreadId);
  else localStorage.removeItem("privmsg.activeThread");
  if (refresh) refreshAll();
}

function renderThreads() {
  ui.threadList.replaceChildren();
  const threads = allThreads();
  if (!threads.length) return ui.threadList.append(emptyCard("No conversations yet"));

  for (const thread of threads) {
    const related = messages.filter(message => effectiveThreadId(message) === thread.id);
    const entry = document.createElement("div");
    entry.className = `thread-entry${thread.id === activeThreadId ? " active" : ""}`;
    const select = document.createElement("button");
    select.type = "button";
    select.className = "thread-select";
    select.innerHTML = `<span class="thread-date">${escapeHtml(formatThreadDate(thread))}</span><span class="thread-summary">${escapeHtml(threeWordSummary(related))}</span><span class="thread-count">${related.length} message${related.length === 1 ? "" : "s"}</span>`;
    select.addEventListener("click", () => {
      setActiveThread(thread.id);
      ui.drawer.classList.remove("open");
      ui.backdrop.classList.remove("open");
    });
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "thread-delete";
    remove.setAttribute("aria-label", "Delete conversation");
    remove.innerHTML = "🗑";
    remove.addEventListener("click", () => deleteThread(thread));
    entry.append(select, remove);
    ui.threadList.append(entry);
  }
}

async function deleteThread(thread) {
  if (!confirm("Delete this entire conversation, including its messages, attachments, and saved recordings?")) return;
  const relatedMessages = messages.filter(message => effectiveThreadId(message) === thread.id);
  const relatedRecordings = recordings.filter(item => item.threadId === thread.id);
  try {
    for (const message of relatedMessages) await deleteMessageAndFiles(message);
    for (const recording of relatedRecordings) await deleteRecordingAndChunks(recording);
    const explicit = threadDocs.find(item => (item.id?.startsWith("thread_") ? item.id.slice(7) : item.id) === thread.id);
    if (explicit) await deleteDoc(doc(db, COLL, explicit.id.startsWith("thread_") ? explicit.id : `thread_${thread.id}`));
    if (activeThreadId === thread.id) setActiveThread("");
    await ensureDailyThread();
    showToast("Conversation deleted");
  } catch (error) {
    console.error(error);
    showToast("Conversation could not be deleted.", true);
  }
}

async function deleteMessageAndFiles(message) {
  const attachments = Array.isArray(message.attachments) ? message.attachments : (message.images || []);
  for (const attachment of attachments) {
    await deleteChunkSet(attachment.key, attachment.chunks);
    if (attachment.preview?.key) await deleteChunkSet(attachment.preview.key, attachment.preview.chunks);
  }
  await deleteDoc(doc(db, COLL, message.id));
}

function filterMessages() {
  const messageMap = new Map(messages.map(item => [item.id, item]));
  const children = [...messageList.children];
  for (const child of children) {
    if (!child.classList.contains("message-row")) continue;
    const message = messageMap.get(child.dataset.messageId);
    const visible = message && effectiveThreadId(message) === activeThreadId;
    child.hidden = !visible;
  }
  for (let index = 0; index < children.length; index++) {
    const child = children[index];
    if (!child.classList.contains("day-divider")) continue;
    let visible = false;
    for (let next = index + 1; next < children.length && !children[next].classList.contains("day-divider"); next++) {
      if (children[next].classList.contains("message-row") && !children[next].hidden) { visible = true; break; }
    }
    child.hidden = !visible;
  }
  const hasVisible = children.some(child => child.classList.contains("message-row") && !child.hidden);
  if (emptyState) {
    emptyState.hidden = hasVisible;
    const heading = emptyState.querySelector("h2");
    const paragraph = emptyState.querySelector("p");
    if (heading) heading.textContent = "New conversation";
    if (paragraph) paragraph.textContent = "Send a message, image, file, or recording to begin.";
  }
}

function renderRecordings() {
  window.dispatchEvent(new CustomEvent("privmsg:recordings", { detail: { recordings } }));
  ui.recordingList.replaceChildren();
  const list = recordings.filter(item => !activeThreadId || item.threadId === activeThreadId);
  if (!list.length) return ui.recordingList.append(emptyCard("No saved recordings in this conversation"));

  for (const recording of list) {
    const entry = document.createElement("div");
    entry.className = "recording-entry";
    const top = document.createElement("div");
    top.className = "recording-top";
    const play = document.createElement("button");
    play.type = "button";
    play.className = "recording-play";
    play.setAttribute("aria-label", `Load ${recording.name || "recording"}`);
    play.innerHTML = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="m8 5 11 7-11 7z"/></svg>';
    const info = document.createElement("div");
    info.className = "recording-info";
    info.innerHTML = `<span class="recording-name">${escapeHtml(recording.name || "Saved recording")}</span><span class="recording-meta">${escapeHtml(formatDuration(recording.durationMs))} · ${escapeHtml(formatBytes(recording.size))} · ${escapeHtml(formatDateTime(recording.createdAt))}</span>`;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "recording-delete";
    remove.setAttribute("aria-label", "Delete recording");
    remove.textContent = "✕";
    top.append(play, info, remove);
    entry.append(top);
    play.addEventListener("click", () => loadRecordingPlayer(recording, entry, play));
    remove.addEventListener("click", () => deleteRecording(recording));
    ui.recordingList.append(entry);
  }
}

async function loadRecordingPlayer(recording, entry, button) {
  const existing = entry.querySelector("audio");
  if (existing) { existing.play().catch(() => {}); return; }
  button.disabled = true;
  button.textContent = "…";
  try {
    const url = await getRecordingUrl(recording);
    const audio = document.createElement("audio");
    audio.className = "recording-player";
    audio.controls = true;
    audio.preload = "metadata";
    audio.src = url;
    const download = document.createElement("a");
    download.className = "recording-download";
    download.href = url;
    download.download = recording.name || "recording";
    download.textContent = "Download recording";
    entry.append(audio, download);
    audio.play().catch(() => {});
    button.innerHTML = "▶";
  } catch (error) {
    console.error(error);
    button.innerHTML = "▶";
    showToast("The saved recording could not be loaded.", true);
  } finally {
    button.disabled = false;
  }
}

async function deleteRecording(recording) {
  if (!confirm("Delete this saved recording permanently?")) return;
  try {
    await deleteRecordingAndChunks(recording);
    showToast("Recording deleted");
  } catch (error) {
    console.error(error);
    showToast("Recording could not be deleted.", true);
  }
}

async function deleteRecordingAndChunks(recording) {
  await deleteChunkSet(recording.key, recording.chunks);
  await deleteDoc(doc(db, COLL, recording.id));
  const url = RECORDING_CACHE.get(recording.key);
  if (url) URL.revokeObjectURL(url);
  RECORDING_CACHE.delete(recording.key);
}

async function getRecordingUrl(recording) {
  if (RECORDING_CACHE.has(recording.key)) return RECORDING_CACHE.get(recording.key);
  const count = Number(recording.chunks);
  const parts = await mapConcurrency(count, 8, async index => {
    const snapshot = await getDoc(doc(db, COLL, `chunk_${recording.key}_${index}`));
    if (!snapshot.exists()) throw new Error("Recording data is incomplete");
    return base64ToBytes(String(snapshot.data().data || ""));
  });
  const blob = new Blob(parts, { type: recording.type || "audio/webm" });
  const url = URL.createObjectURL(blob);
  RECORDING_CACHE.set(recording.key, url);
  return url;
}

async function deleteChunkSet(key, chunks) {
  const count = Number(chunks) || 0;
  if (!key || count < 1) return;
  await mapConcurrency(count, 8, index => deleteDoc(doc(db, COLL, `chunk_${key}_${index}`)));
}

function effectiveThreadId(message) { return message.threadId || `legacy-${messageDateKey(message)}`; }
function messageDateKey(message) { return localDateKey(new Date(toMillis(message.createdAt))); }
function localDateKey(date) { return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`; }
function threadSortTime(thread) {
  const related = messages.filter(message => effectiveThreadId(message) === thread.id);
  if (related.length) return Math.max(...related.map(item => toMillis(item.createdAt)));
  return toMillis(thread.createdAt);
}
function formatThreadDate(thread) {
  const date = thread.dateKey ? new Date(`${thread.dateKey}T12:00:00`) : new Date(toMillis(thread.createdAt));
  return date.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric", year: date.getFullYear() === new Date().getFullYear() ? undefined : "numeric" });
}
function threeWordSummary(threadMessages) {
  const words = threadMessages.flatMap(item => String(item.text || "").toLowerCase().match(/[a-z0-9']+/g) || []);
  const counts = new Map();
  for (const word of words) {
    if (word.length < 3 || STOP_WORDS.has(word)) continue;
    counts.set(word, (counts.get(word) || 0) + 1);
  }
  const top = [...counts].sort((a, b) => b[1] - a[1] || b[0].length - a[0].length).slice(0, 3).map(([word]) => word);
  if (top.length) return top.map(word => word[0].toUpperCase() + word.slice(1)).join(" ");
  const attachmentCount = threadMessages.reduce((total, item) => total + (item.attachments?.length || item.images?.length || 0), 0);
  return attachmentCount ? "Shared Files" : "New Conversation";
}
function toMillis(timestamp) {
  if (timestamp && typeof timestamp.toMillis === "function") return timestamp.toMillis();
  if (typeof timestamp === "number") return timestamp;
  return Date.now();
}
function formatDuration(ms) {
  const seconds = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}
function formatBytes(bytes) {
  const value = Number(bytes) || 0;
  if (!value) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  const index = Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1);
  const amount = value / (1024 ** index);
  return `${amount >= 10 || index === 0 ? Math.round(amount) : amount.toFixed(1)} ${units[index]}`;
}
function formatDateTime(timestamp) { return new Date(toMillis(timestamp)).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }); }
function extensionForAudio(type) { return String(type).includes("mp4") ? "m4a" : String(type).includes("ogg") ? "ogg" : "webm"; }
function emptyCard(text) { const element = document.createElement("div"); element.className = "drawer-empty"; element.textContent = text; return element; }
function escapeHtml(value) { const span = document.createElement("span"); span.textContent = String(value ?? ""); return span.innerHTML; }

function bytesToBase64(bytes) {
  const segments = [];
  for (let index = 0; index < bytes.length; index += 32768) segments.push(String.fromCharCode(...bytes.subarray(index, index + 32768)));
  return btoa(segments.join(""));
}
function base64ToBytes(value) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}
function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || "").split(",")[1] || "");
    reader.onerror = () => reject(new Error("Could not prepare the recording."));
    reader.readAsDataURL(blob);
  });
}
async function mapConcurrency(count, limit, callback) {
  const results = new Array(count);
  let next = 0;
  async function worker() {
    while (next < count) {
      const index = next++;
      results[index] = await callback(index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(count, limit) }, worker));
  return results;
}

function showToast(message, isError = false) {
  const element = document.querySelector("#toast");
  if (!element) return;
  element.textContent = message;
  element.classList.toggle("error", isError);
  element.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => element.classList.remove("show"), isError ? 4800 : 2600);
}

window.__privmsgRecorderBusy = () => recorderBusy || recorder != null;
