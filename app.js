const STORAGE_KEY = "jarvisReaderConfigV3";
const SUPABASE_URL = "https://ifslruvbvudjocwqcxmg.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_6LA1DysdfyGw-SyJa0GClQ_c2zSqxVB";

const app = document.querySelector("#app");
const settingsDialog = document.querySelector("#settingsDialog");
const settingsForm = document.querySelector("#settingsForm");

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
let pollTimer = null;

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

function getMode() {
  return new URLSearchParams(location.search).get("mode") === "glasses" ? "glasses" : "phone";
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

function supabaseHeaders(contentType = false) {
  const headers = {
    apikey: SUPABASE_PUBLISHABLE_KEY,
    Authorization: `Bearer ${SUPABASE_PUBLISHABLE_KEY}`,
    "x-jarvis-session": config.sessionId,
    Accept: "application/json"
  };

  if (contentType) headers["Content-Type"] = "application/json";
  return headers;
}

async function fetchLatestResponse() {
  const session = encodeURIComponent(config.sessionId);
  const url = `${SUPABASE_URL}/rest/v1/jarvis_responses?select=id,answer,created_at&session_id=eq.${session}&order=created_at.desc&limit=1`;

  const response = await fetch(url, {
    headers: supabaseHeaders(),
    cache: "no-store"
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    if (response.status === 404 || detail.includes("jarvis_responses")) {
      throw new Error("Database setup needed");
    }
    throw new Error(`Supabase ${response.status}`);
  }

  const rows = await response.json();
  return rows[0] || null;
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
  const setup = [
    `Supabase URL: ${SUPABASE_URL}`,
    `Publishable key: ${SUPABASE_PUBLISHABLE_KEY}`,
    `Session key: ${config.sessionId}`,
    "Table: jarvis_responses"
  ].join("\n");

  await copyText(setup, "Shortcut setup copied.");
}

function setPhoneStatus(text, state = "") {
  const label = document.querySelector("#phoneStatusText");
  const dot = document.querySelector("#phoneStatusDot");
  if (label) label.textContent = text;
  if (dot) dot.className = `status-dot ${state}`.trim();
}

async function refreshPhoneStatus() {
  try {
    const row = await fetchLatestResponse();
    if (!row) {
      setPhoneStatus("Supabase connected. Waiting for first answer.", "live");
      return;
    }

    const stamp = new Date(row.created_at).toLocaleTimeString([], {
      hour: "numeric",
      minute: "2-digit"
    });
    setPhoneStatus(`Supabase connected. Last answer ${stamp}.`, "live");
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
        <p class="subtext">Take a photo with your glasses, then process the latest photo with the JARVIS Reader Shortcut.</p>
      </div>

      <button id="answerButton" class="primary">PROCESS LATEST PHOTO</button>
      <button id="copyGlassesLink" class="secondary" style="margin-top:12px">COPY GLASSES LINK</button>
      <button id="copyShortcutSetup" class="secondary" style="margin-top:12px">COPY SHORTCUT SETUP</button>

      <div class="status-card status-row">
        <div class="row" style="justify-content:flex-start">
          <span id="phoneStatusDot" class="status-dot"></span>
          <span id="phoneStatusText">Checking Supabase…</span>
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
  document.querySelector("#copyShortcutSetup").addEventListener("click", copyShortcutSetup);

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
  try {
    const row = await fetchLatestResponse();
    if (!row) {
      renderGlassesState("JARVIS Reader", "READY", "Waiting for answer");
      return;
    }

    const stamp = new Date(row.created_at).toLocaleTimeString([], {
      hour: "numeric",
      minute: "2-digit"
    });
    renderGlassesState("JARVIS", row.answer || "No answer returned", stamp);
  } catch (error) {
    renderGlassesState("CONNECTION", "Offline", error.message);
  }
}

function renderGlasses() {
  clearInterval(pollTimer);
  renderGlassesState("JARVIS Reader", "READY", "Connecting…");
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
