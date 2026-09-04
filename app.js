const STORAGE_KEY = "jarvisReaderConfigV1";
const app = document.querySelector("#app");
const settingsDialog = document.querySelector("#settingsDialog");
const settingsForm = document.querySelector("#settingsForm");

const defaultConfig = {
  supabaseUrl: "",
  supabaseKey: "",
  sessionId: "jarvis-ben",
  shortcutName: "JARVIS Reader"
};

let config = loadConfig();
let pollTimer = null;
let latestResponseId = null;

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

function getMode() {
  const mode = new URLSearchParams(location.search).get("mode");
  return mode === "glasses" ? "glasses" : "phone";
}

function normalizeBaseUrl(url) {
  return (url || "").trim().replace(/\/+$/, "");
}

function hasRelayConfig() {
  return Boolean(config.supabaseUrl && config.supabaseKey && config.sessionId);
}

function hydrateConfigFromUrl() {
  const params = new URLSearchParams(location.search);
  const imported = {
    supabaseUrl: params.get("sb") || config.supabaseUrl,
    supabaseKey: params.get("key") || config.supabaseKey,
    sessionId: params.get("session") || config.sessionId,
    shortcutName: params.get("shortcut") || config.shortcutName
  };

  if (params.has("sb") || params.has("key") || params.has("session") || params.has("shortcut")) {
    saveConfig(imported);
    ["sb", "key", "session", "shortcut"].forEach((key) => params.delete(key));
    const query = params.toString();
    history.replaceState({}, "", `${location.pathname}${query ? `?${query}` : ""}${location.hash}`);
  }
}

function supabaseHeaders() {
  return {
    apikey: config.supabaseKey,
    Authorization: `Bearer ${config.supabaseKey}`,
    "Content-Type": "application/json"
  };
}

async function fetchLatestResponse() {
  if (!hasRelayConfig()) return null;

  const base = normalizeBaseUrl(config.supabaseUrl);
  const session = encodeURIComponent(config.sessionId);
  const url = `${base}/rest/v1/jarvis_responses?select=id,answer,created_at&session_id=eq.${session}&order=created_at.desc&limit=1`;
  const response = await fetch(url, { headers: supabaseHeaders(), cache: "no-store" });

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`Relay ${response.status}${detail ? `: ${detail}` : ""}`);
  }

  const rows = await response.json();
  return rows[0] || null;
}

function openSettings() {
  document.querySelector("#supabaseUrl").value = config.supabaseUrl;
  document.querySelector("#supabaseKey").value = config.supabaseKey;
  document.querySelector("#sessionId").value = config.sessionId;
  document.querySelector("#shortcutName").value = config.shortcutName;
  settingsDialog.showModal();
}

function wireSettings() {
  settingsForm.addEventListener("submit", (event) => {
    event.preventDefault();
    saveConfig({
      supabaseUrl: document.querySelector("#supabaseUrl").value.trim(),
      supabaseKey: document.querySelector("#supabaseKey").value.trim(),
      sessionId: document.querySelector("#sessionId").value.trim() || defaultConfig.sessionId,
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

async function copyGlassesLink() {
  if (!hasRelayConfig()) {
    openSettings();
    return;
  }

  const url = new URL(location.href);
  url.search = "";
  url.searchParams.set("mode", "glasses");
  url.searchParams.set("sb", config.supabaseUrl);
  url.searchParams.set("key", config.supabaseKey);
  url.searchParams.set("session", config.sessionId);

  try {
    await navigator.clipboard.writeText(url.toString());
    setPhoneStatus("Glasses setup link copied. Open it once on the glasses.", "live");
  } catch {
    prompt("Copy this glasses URL:", url.toString());
  }
}

function setPhoneStatus(text, state = "") {
  const label = document.querySelector("#phoneStatusText");
  const dot = document.querySelector("#phoneStatusDot");
  if (label) label.textContent = text;
  if (dot) dot.className = `status-dot ${state}`.trim();
}

async function refreshPhoneStatus() {
  if (!hasRelayConfig()) {
    setPhoneStatus("Connect Supabase before using the relay.");
    return;
  }

  try {
    const row = await fetchLatestResponse();
    if (!row) {
      setPhoneStatus("Connected. Waiting for the first response.", "live");
      return;
    }
    const stamp = new Date(row.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    setPhoneStatus(`Connected. Last response ${stamp}.`, "live");
  } catch (error) {
    setPhoneStatus(error.message, "error");
  }
}

function renderPhone() {
  clearInterval(pollTimer);
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
        <p class="subtext">Take a photo with your glasses, then run the Shortcut from here.</p>
      </div>

      <button id="answerButton" class="primary">PROCESS LATEST PHOTO</button>
      <button id="copyGlassesLink" class="secondary" style="margin-top:12px">COPY GLASSES SETUP LINK</button>

      <div class="status-card status-row">
        <div class="row" style="justify-content:flex-start">
          <span id="phoneStatusDot" class="status-dot"></span>
          <span id="phoneStatusText">Checking connection…</span>
        </div>
      </div>

      <div class="row" style="margin-top:16px">
        <span class="small">Phone mode</span>
        <a class="small link-button" href="?mode=glasses">Preview glasses view</a>
      </div>
    </section>
  `;

  document.querySelector("#settingsButton").addEventListener("click", openSettings);
  document.querySelector("#answerButton").addEventListener("click", launchShortcut);
  document.querySelector("#copyGlassesLink").addEventListener("click", copyGlassesLink);
  refreshPhoneStatus();
  pollTimer = setInterval(refreshPhoneStatus, 7000);
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

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function refreshGlasses() {
  if (!hasRelayConfig()) {
    renderGlassesState("JARVIS Reader", "Setup needed", "Open the copied glasses setup URL once.");
    return;
  }

  try {
    const row = await fetchLatestResponse();
    if (!row) {
      renderGlassesState("JARVIS Reader", "READY", "Waiting for a response");
      return;
    }

    if (latestResponseId !== row.id) latestResponseId = row.id;
    const stamp = new Date(row.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    renderGlassesState("JARVIS", row.answer || "No answer returned", stamp);
  } catch (error) {
    renderGlassesState("CONNECTION", "Offline", "Check relay settings");
  }
}

function renderGlasses() {
  clearInterval(pollTimer);
  renderGlassesState("JARVIS Reader", "READY", hasRelayConfig() ? "Connecting…" : "Setup needed");
  refreshGlasses();
  pollTimer = setInterval(refreshGlasses, 1500);
}

function render() {
  getMode() === "glasses" ? renderGlasses() : renderPhone();
}

hydrateConfigFromUrl();
wireSettings();
render();

if ("serviceWorker" in navigator) {
  addEventListener("load", () => navigator.serviceWorker.register("./sw.js").catch(() => {}));
}
