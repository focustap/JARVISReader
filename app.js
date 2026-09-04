const STORAGE_KEY = "jarvisReaderConfigV2";
const app = document.querySelector("#app");
const settingsDialog = document.querySelector("#settingsDialog");
const settingsForm = document.querySelector("#settingsForm");

const defaultConfig = {
  relayUrl: "",
  relayToken: "",
  sessionId: "jarvis-ben",
  shortcutName: "JARVIS Reader"
};

let config = loadConfig();
let pollTimer = null;

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
  return new URLSearchParams(location.search).get("mode") === "glasses" ? "glasses" : "phone";
}

function hasRelayConfig() {
  return Boolean(config.relayUrl && config.sessionId);
}

function normalizeUrl(url) {
  return (url || "").trim().replace(/\/+$/, "");
}

function hydrateConfigFromUrl() {
  const params = new URLSearchParams(location.search);
  const keys = ["relay", "token", "session", "shortcut"];
  if (!keys.some((key) => params.has(key))) return;

  saveConfig({
    relayUrl: params.get("relay") || config.relayUrl,
    relayToken: params.get("token") || config.relayToken,
    sessionId: params.get("session") || config.sessionId,
    shortcutName: params.get("shortcut") || config.shortcutName
  });

  keys.forEach((key) => params.delete(key));
  const query = params.toString();
  history.replaceState({}, "", `${location.pathname}${query ? `?${query}` : ""}${location.hash}`);
}

function relayHeaders() {
  const headers = { Accept: "application/json" };
  if (config.relayToken) headers.Authorization = `Bearer ${config.relayToken}`;
  return headers;
}

async function fetchLatestResponse() {
  if (!hasRelayConfig()) return null;
  const url = new URL(`${normalizeUrl(config.relayUrl)}/latest`);
  url.searchParams.set("session", config.sessionId);

  const response = await fetch(url, {
    headers: relayHeaders(),
    cache: "no-store"
  });

  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Relay ${response.status}`);

  const data = await response.json();
  if (!data || typeof data.answer !== "string") return null;
  return data;
}

function openSettings() {
  document.querySelector("#relayUrl").value = config.relayUrl;
  document.querySelector("#relayToken").value = config.relayToken;
  document.querySelector("#sessionId").value = config.sessionId;
  document.querySelector("#shortcutName").value = config.shortcutName;
  settingsDialog.showModal();
}

function wireSettings() {
  settingsForm.addEventListener("submit", (event) => {
    event.preventDefault();
    saveConfig({
      relayUrl: document.querySelector("#relayUrl").value.trim(),
      relayToken: document.querySelector("#relayToken").value.trim(),
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
  const url = new URL(location.href);
  url.search = "";
  url.searchParams.set("mode", "glasses");

  if (hasRelayConfig()) {
    url.searchParams.set("relay", config.relayUrl);
    if (config.relayToken) url.searchParams.set("token", config.relayToken);
    url.searchParams.set("session", config.sessionId);
  }

  try {
    await navigator.clipboard.writeText(url.toString());
    setPhoneStatus("Glasses link copied.", "live");
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
    setPhoneStatus("Frontend ready. Relay not configured yet.");
    return;
  }

  try {
    const row = await fetchLatestResponse();
    if (!row) {
      setPhoneStatus("Relay connected. Waiting for first answer.", "live");
      return;
    }
    setPhoneStatus("Relay connected.", "live");
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
        <p class="subtext">Take a photo with your glasses, then run the JARVIS Reader Shortcut.</p>
      </div>

      <button id="answerButton" class="primary">PROCESS LATEST PHOTO</button>
      <button id="copyGlassesLink" class="secondary" style="margin-top:12px">COPY GLASSES LINK</button>

      <div class="status-card status-row">
        <div class="row" style="justify-content:flex-start">
          <span id="phoneStatusDot" class="status-dot"></span>
          <span id="phoneStatusText">Checking…</span>
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

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
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

async function refreshGlasses() {
  if (!hasRelayConfig()) {
    renderGlassesState("JARVIS Reader", "READY", "Frontend only — relay not configured");
    return;
  }

  try {
    const row = await fetchLatestResponse();
    if (!row) {
      renderGlassesState("JARVIS Reader", "READY", "Waiting for answer");
      return;
    }

    const meta = row.createdAt
      ? new Date(row.createdAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
      : "";
    renderGlassesState("JARVIS", row.answer, meta);
  } catch {
    renderGlassesState("CONNECTION", "Offline", "Check relay settings");
  }
}

function renderGlasses() {
  clearInterval(pollTimer);
  renderGlassesState("JARVIS Reader", "READY", hasRelayConfig() ? "Connecting…" : "Frontend only");
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
