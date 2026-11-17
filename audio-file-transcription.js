// Adds "Transcribe audio" to PrivMsg's attachment menu and routes selected files
// through the same Firebase callable used by microphone transcription.
import {
  getApp,
  getApps,
  initializeApp
} from "https://www.gstatic.com/firebasejs/12.16.0/firebase-app.js";
import {
  getAuth
} from "https://www.gstatic.com/firebasejs/12.16.0/firebase-auth.js";
import {
  getFunctions,
  httpsCallable
} from "https://www.gstatic.com/firebasejs/12.16.0/firebase-functions.js";

const firebaseConfig = {
  apiKey: "AIzaSyD3dBLNLnDdzURfor0B4v6hXuUb5LSr4zU",
  authDomain: "privmsg-stream.firebaseapp.com",
  projectId: "privmsg-stream",
  storageBucket: "privmsg-stream.firebasestorage.app",
  messagingSenderId: "988675611975",
  appId: "1:988675611975:web:a2f0bea735a33182094062",
  measurementId: "G-EG0SR5ED6N"
};

const MAX_AUDIO_BYTES = 20 * 1024 * 1024;
const AUDIO_ACCEPT = [
  "audio/*",
  ".aac",
  ".flac",
  ".m4a",
  ".mp3",
  ".mp4",
  ".mpeg",
  ".mpga",
  ".oga",
  ".ogg",
  ".wav",
  ".webm"
].join(",");
const AUDIO_EXTENSION = /\.(aac|flac|m4a|mp3|mp4|mpeg|mpga|oga|ogg|wav|webm)$/i;

const attachmentMenu = document.querySelector("#attachmentMenu");
const uploadButton = document.querySelector("#uploadButton");
const attachButton = document.querySelector("#attachButton");
const micButton = document.querySelector("#micButton");
const messageInput = document.querySelector("#messageInput");
const composerMeta = document.querySelector("#composerMeta");
const progress = document.querySelector("#transcriptionProgress");
const progressBar = document.querySelector("#transcriptionProgressBar");
const toastElement = document.querySelector("#toast");

let busy = false;
let toastTimer = null;
let progressTimer = null;
let progressValue = 0;

if (
  attachmentMenu &&
  uploadButton &&
  attachButton &&
  micButton &&
  messageInput &&
  composerMeta &&
  progress &&
  progressBar &&
  toastElement &&
  !document.querySelector("#transcribeAudioUploadButton")
) {
  installAudioUploadTranscription();
}

function installAudioUploadTranscription() {
  const audioInput = document.createElement("input");
  audioInput.id = "transcribeAudioFileInput";
  audioInput.type = "file";
  audioInput.accept = AUDIO_ACCEPT;
  audioInput.multiple = true;
  audioInput.hidden = true;

  const button = document.createElement("button");
  button.className = "menu-item";
  button.id = "transcribeAudioUploadButton";
  button.type = "button";
  button.innerHTML = `
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d="M9 18V5l10-2v13"/>
      <circle cx="6" cy="18" r="3"/>
      <circle cx="16" cy="16" r="3"/>
    </svg>
    Transcribe audio
  `;

  uploadButton.insertAdjacentElement("afterend", button);
  document.body.append(audioInput);

  button.addEventListener("click", event => {
    event.preventDefault();
    event.stopPropagation();
    attachmentMenu.hidden = true;
    attachButton.setAttribute("aria-expanded", "false");

    if (busy) return;
    if (micButton.classList.contains("is-recording")) {
      showToast("Stop the current recording before transcribing a file.", true);
      return;
    }
    if (progress.classList.contains("active")) {
      showToast("Another transcription is already running.", true);
      return;
    }

    audioInput.click();
  });

  audioInput.addEventListener("change", async () => {
    const files = [...(audioInput.files || [])];
    audioInput.value = "";
    if (!files.length) return;
    await transcribeFiles(files, button);
  });
}

async function transcribeFiles(files, button) {
  if (busy) return;

  const supported = files.filter(isAudioFile);
  const unsupportedCount = files.length - supported.length;
  if (unsupportedCount) {
    showToast(
      `${unsupportedCount} non-audio file${unsupportedCount === 1 ? " was" : "s were"} skipped.`,
      true
    );
  }
  if (!supported.length) return;

  const tooLarge = supported.find(file => file.size > MAX_AUDIO_BYTES);
  if (tooLarge) {
    showToast(`${tooLarge.name || "That audio file"} exceeds the 20 MB transcription limit.`, true);
    return;
  }

  const empty = supported.find(file => !file.size);
  if (empty) {
    showToast(`${empty.name || "That audio file"} is empty.`, true);
    return;
  }

  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  const auth = getAuth(app);
  if (!auth.currentUser) {
    showToast("Sign in before transcribing an audio file.", true);
    return;
  }

  const transcribeAudio = httpsCallable(
    getFunctions(app, "us-central1"),
    "transcribeAudio",
    { timeout: 540000 }
  );

  busy = true;
  button.disabled = true;
  beginProgress();

  try {
    for (let index = 0; index < supported.length; index++) {
      const file = supported[index];
      composerMeta.textContent = supported.length === 1
        ? `Transcribing ${file.name || "audio"}…`
        : `Transcribing ${index + 1} of ${supported.length} · ${file.name || "audio"}…`;

      const response = await transcribeAudio({
        audioBase64: await blobToBase64(file),
        mimeType: normalizedMimeType(file),
        fileName: file.name || `audio-${Date.now()}`
      });

      const transcript = String(response?.data?.text || "").trim();
      if (!transcript) {
        throw new Error(`${file.name || "The audio file"} returned an empty transcript.`);
      }

      appendTranscript(transcript);
      setProgress(((index + 1) / supported.length) * 94);
    }

    showToast(
      supported.length === 1
        ? "Audio transcribed."
        : `${supported.length} audio files transcribed.`
    );
  } catch (error) {
    console.error(error);
    showToast(`Transcription failed: ${friendlyTranscriptionError(error)}`, true);
  } finally {
    composerMeta.textContent = "";
    finishProgress();
    busy = false;
    button.disabled = false;
    messageInput.focus();
  }
}

function isAudioFile(file) {
  const type = String(file?.type || "").toLowerCase();
  return Boolean(file && (type.startsWith("audio/") || AUDIO_EXTENSION.test(String(file.name || ""))));
}

function normalizedMimeType(file) {
  const extension = (String(file?.name || "").match(/\.([^.]+)$/) || [])[1]?.toLowerCase();
  const byExtension = {
    aac: "audio/aac",
    flac: "audio/flac",
    m4a: "audio/mp4",
    mp3: "audio/mpeg",
    mp4: "audio/mp4",
    mpeg: "audio/mpeg",
    mpga: "audio/mpeg",
    oga: "audio/ogg",
    ogg: "audio/ogg",
    wav: "audio/wav",
    webm: "audio/webm"
  };
  return byExtension[extension] || String(file?.type || "audio/mpeg");
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const value = String(reader.result || "");
      const comma = value.indexOf(",");
      resolve(comma >= 0 ? value.slice(comma + 1) : value);
    };
    reader.onerror = () => reject(new Error("Could not prepare the audio file for transcription."));
    reader.readAsDataURL(blob);
  });
}

function appendTranscript(text) {
  const clean = String(text || "").trim();
  if (!clean) return;

  const start = Number.isInteger(messageInput.selectionStart)
    ? messageInput.selectionStart
    : messageInput.value.length;
  const end = Number.isInteger(messageInput.selectionEnd)
    ? messageInput.selectionEnd
    : start;
  const before = messageInput.value.slice(0, start);
  const after = messageInput.value.slice(end);
  const leading = before && !/\s$/.test(before) ? " " : "";
  const trailing = after && !/^\s/.test(after) ? " " : "";
  const inserted = leading + clean + trailing;

  messageInput.value = before + inserted + after;
  const caret = before.length + inserted.length;
  messageInput.setSelectionRange(caret, caret);
  messageInput.dispatchEvent(new Event("input", { bubbles: true }));
}

function friendlyTranscriptionError(error) {
  switch (error?.code) {
    case "functions/unauthenticated":
      return "your sign-in expired; reload and sign in again.";
    case "functions/permission-denied":
      return "this account is not authorized to transcribe audio.";
    case "functions/invalid-argument":
      return "the selected audio format was not accepted.";
    case "functions/resource-exhausted":
      return "the file is too large, or the OpenAI quota was reached.";
    case "functions/failed-precondition":
      return "the linked OpenAI API key was rejected.";
    case "functions/deadline-exceeded":
      return "the request took too long; try a shorter file.";
    case "functions/unavailable":
      return "the transcription service is temporarily unavailable.";
    case "functions/internal":
      return "the transcription service returned an internal error.";
    default:
      return String(error?.message || "unknown error");
  }
}

function beginProgress() {
  clearInterval(progressTimer);
  progressValue = 4;
  progress.classList.add("active");
  progress.setAttribute("aria-hidden", "false");
  setProgress(progressValue);

  progressTimer = setInterval(() => {
    progressValue = Math.min(88, progressValue + Math.max(0.35, (88 - progressValue) * 0.025));
    setProgress(progressValue);
  }, 500);
}

function setProgress(value) {
  progressValue = Math.max(0, Math.min(100, Number(value) || 0));
  progressBar.style.transform = `scaleX(${progressValue / 100})`;
  progress.setAttribute("aria-valuenow", String(Math.round(progressValue)));
}

function finishProgress() {
  clearInterval(progressTimer);
  progressTimer = null;
  setProgress(100);
  setTimeout(() => {
    progress.classList.remove("active");
    progress.setAttribute("aria-hidden", "true");
    setProgress(0);
  }, 280);
}

function showToast(message, isError = false) {
  clearTimeout(toastTimer);
  toastElement.textContent = message;
  toastElement.classList.toggle("error", isError);
  toastElement.classList.add("show");
  toastTimer = setTimeout(() => toastElement.classList.remove("show"), 4300);
}
