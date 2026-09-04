const STORAGE_KEY = "jarvisReaderConfigV4";
const LAST_ANSWER_PREFIX = "jarvisReaderLastAnswerV1:";
const SUPABASE_URL = "https://ifslruvbvudjocwqcxmg.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_6LA1DysdfyGw-SyJa0GClQ_c2zSqxVB";

const app = document.querySelector("#app");
const settingsDialog = document.querySelector("#settingsDialog");
const settingsForm = document.querySelector("#settingsForm");

const supabaseClient = window.supabase?.createClient(
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY,
  {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false
    }
  }
);

function createSessionKey() {
  if (crypto?.randomUUID) {
    return `jr_${crypto.randomUUID()}_${crypto.randomUUID()}`;
  }

  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `jr_${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")}`;
}

const defaultConfig = {
  sessionId: "",
  shortcutName: "JARVIS Reader"
};

let config = loadConfig();
let realtimeChannel = null;

if (!config.sessionId) {
  config.sessionId = createSessionKey();
  saveConfig(config);
}

function loadConfig() {
  try {
    return { ...defaultConfig, ...JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}") };
  } catch {
    return { ...defaultConfig };
  }
}

function saveConfig(next) {
  config = { ...defaultConfig, ...next };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
}

function lastAnswerKey() {
  return `${LAST_ANSWER_PREFIX}${config.sessionId}`;
}

function saveLastAnswer(answer, createdAt = new Date().toISOString()) {
  const record = { answer, createdAt };
  localStorage.setItem(lastAnswerKey(), JSON.stringify(record));
  return record;
}

function loadLastAnswer() {
  try {
    const value = JSON.parse(localStorage.getItem(lastAnswerKey()) || "null");
    return value && typeof value.answer === "string" ? value : null;
  } catch {
    return null;
  }
}

function getMode() {
  return new URLSearchParams(location.search).get("mode") === "glasses" ? "glasses" : "phone";
}

function topicName() {
  return `jarvis-${config.sessionId}`;
}

function hydrateConfigFromUrl() {
  const params = new URLSearchParams(location.search);
  if (!params.has("session") && !params.has("shortcut")) return;

  saveConfig({
    sessionId: params.get("session") || config.sessionId,
    shortcutName: params.get("shortcut") || config.shortcutName
  });

  params.delete("session");
  params.delete("shortcut");
  const query = params.toString();
  history.replaceState({}, "", `${location.pathname}${query ? `?${query}` : ""}${location.hash}`);
}

function openSettings() {
  document.querySelector("#sessionId").value = config.sessionId;
  document.querySelector("#shortcutName").value = config.shortcutName;
  settingsDialog.showModal();
}

function wireSettings() {
  settingsForm.addEventListener("submit", (event) => {
    event.preventDefault();
    saveConfig({
      sessionId: document.querySelector("#sessionId").value.trim() || createSessionKey(),
      shortcutName: document.querySelector("#shortcutName").value.trim() || defaultConfig.shortcutName
    });
    settingsDialog.close();
    render();
  });
}

function launchShortcut() {
  const name = encodeURIComponent(config.shortcutName || defaultConfig.shortcutName);
  location.href = `shortcuts://run-shortcut?name=${name}`;
}

async function copyText(text, successMessage) {
  try {
    await navigator.clipboard.writeText(text);
    setPhoneStatus(successMessage, "live");
  } catch {
    prompt("Copy this:", text);
  }
}

async function copyGlassesLink() {
  const url = new URL(location.href);
  url.search = "";
  url.searchParams.set("mode", "glasses");
  url.searchParams.set("session", config.sessionId);
  await copyText(url.toString(), "Glasses setup link copied.");
}

async function copyShortcutSetup() {
  const topic = encodeURIComponent(topicName());
  const endpoint = `${SUPABASE_URL}/realtime/v1/api/broadcast/${topic}/events/answer`;
  const setup = [
    "JARVIS Reader Shortcut relay",
    `URL: ${endpoint}`,
    "Method: POST",
    `Header apikey: ${SUPABASE_PUBLISHABLE_KEY}`,
    "Header Content-Type: application/json",
    'JSON body: {"answer":"<ChatGPT result>"}',
    "",
    "Use the ChatGPT result variable as the value of answer in Shortcuts."
  ].join("\n");

  await copyText(setup, "Shortcut relay setup copied.");
}

function setPhoneStatus(text, state = "") {
  const label = document.querySelector("#phoneStatusText");
  const dot = document.querySelector("#phoneStatusDot");
  if (label) label.textContent = text;
  if (dot) dot.className = `status-dot ${state}`.trim();
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatTime(value) {
  const date = value ? new Date(value) : new Date();
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

function extractBroadcast(message) {
  const payload = message?.payload ?? message ?? {};

  if (typeof payload === "string") {
    return { answer: payload, createdAt: new Date().toISOString() };
  }

  const answer = payload.answer ?? payload.text ?? payload.response ?? "";
  const createdAt = payload.created_at ?? payload.createdAt ?? new Date().toISOString();

  return {
    answer: typeof answer === "string" ? answer : JSON.stringify(answer),
    createdAt
  };
}

async function disconnectRealtime() {
  if (!realtimeChannel || !supabaseClient) return;
  const channel = realtimeChannel;
  realtimeChannel = null;
  try {
    await supabaseClient.removeChannel(channel);
  } catch {
    // A stale socket should never block rendering a new view.
  }
}

function connectRealtime({ onStatus, onAnswer }) {
  if (!supabaseClient) {
    onStatus?.("Realtime library failed to load", "error");
    return;
  }

  disconnectRealtime();

  const channel = supabaseClient
    .channel(topicName(), { config: { private: false } })
    .on("broadcast", { event: "answer" }, (message) => {
      const result = extractBroadcast(message);
      if (!result.answer) return;

      saveLastAnswer(result.answer, result.createdAt);
      onAnswer?.(result);
    })
    .subscribe((status) => {
      if (channel !== realtimeChannel) return;

      if (status === "SUBSCRIBED") {
        onStatus?.("Realtime connected", "live");
      } else if (status === "CHANNEL_ERROR") {
        onStatus?.("Realtime channel error", "error");
      } else if (status === "TIMED_OUT") {
        onStatus?.("Realtime connection timed out", "error");
      } else if (status === "CLOSED") {
        onStatus?.("Realtime disconnected");
      }
    });

  realtimeChannel = channel;
}

function renderPhone() {
  app.className = "app-shell";
  app.innerHTML = `
    <section class="panel">
      <div class="topbar">
        <div class="brand">
          <div class="logo">JR</div>
          <div>
            <p class="eyebrow">Controller</p>
            <h1>JARVIS Reader</h1>
          </div>
        </div>
        <button id="settingsButton" class="icon-button" aria-label="Settings">⚙</button>
      </div>

      <div class="hero">
        <p class="state">LATEST GLASSES PHOTO</p>
        <p class="headline">Ready.</p>
        <p class="subtext">Take a photo with your glasses, then process it with the JARVIS Reader Shortcut.</p>
      </div>

      <button id="answerButton" class="primary">PROCESS LATEST PHOTO</button>
      <button id="copyGlassesLink" class="secondary" style="margin-top:12px">COPY GLASSES LINK</button>
      <button id="copyShortcutSetup" class="secondary" style="margin-top:12px">COPY SHORTCUT SETUP</button>

      <div class="status-card status-row">
        <div class="row" style="justify-content:flex-start">
          <span id="phoneStatusDot" class="status-dot"></span>
          <span id="phoneStatusText">Connecting Realtime…</span>
        </div>
      </div>

      <div class="row" style="margin-top:16px">
        <span class="small">Phone mode · no polling</span>
        <a class="small link-button" href="?mode=glasses">Preview glasses view</a>
      </div>
    </section>
  `;

  document.querySelector("#settingsButton").addEventListener("click", openSettings);
  document.querySelector("#answerButton").addEventListener("click", launchShortcut);
  document.querySelector("#copyGlassesLink").addEventListener("click", copyGlassesLink);
  document.querySelector("#copyShortcutSetup").addEventListener("click", copyShortcutSetup);

  connectRealtime({
    onStatus: setPhoneStatus,
    onAnswer: ({ createdAt }) => {
      setPhoneStatus(`Answer received ${formatTime(createdAt)}.`, "live");
    }
  });
}

function renderGlassesState(label, answer, meta = "") {
  app.className = "glasses-shell";
  app.innerHTML = `
    <section class="glasses-card">
      <div class="glasses-label">${escapeHtml(label)}</div>
      <div class="glasses-answer">${escapeHtml(answer)}</div>
      ${meta ? `<div class="glasses-meta">${escapeHtml(meta)}</div>` : ""}
    </section>
  `;
}

function renderGlasses() {
  const cached = loadLastAnswer();

  if (cached) {
    renderGlassesState("JARVIS", cached.answer, formatTime(cached.createdAt));
  } else {
    renderGlassesState("JARVIS Reader", "READY", "Connecting Realtime…");
  }

  connectRealtime({
    onStatus: (text, state) => {
      if (state === "error") {
        renderGlassesState("CONNECTION", "Offline", text);
        return;
      }

      if (!loadLastAnswer() && text === "Realtime connected") {
        renderGlassesState("JARVIS Reader", "READY", "Waiting for answer");
      }
    },
    onAnswer: ({ answer, createdAt }) => {
      renderGlassesState("JARVIS", answer, formatTime(createdAt));
    }
  });
}

function render() {
  getMode() === "glasses" ? renderGlasses() : renderPhone();
}

hydrateConfigFromUrl();
wireSettings();
render();

addEventListener("pagehide", () => {
  disconnectRealtime();
});

if ("serviceWorker" in navigator) {
  addEventListener("load", () => navigator.serviceWorker.register("./sw.js").catch(() => {}));
}
