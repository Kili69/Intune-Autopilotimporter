import {
  AccountInfo,
  InteractionRequiredAuthError,
  PublicClientApplication,
} from '@azure/msal-browser';
import { AutopilotDevice, parseAutopilotCsv } from './csv';
import './style.css';

interface RuntimeConfig {
  clientId: string;
  authority: string;
  scope: string;
  redirectUri: string;
  importUrl: string;
  tagsUrl: string;
}

interface ApiError {
  error?: string;
  message?: string;
  correlationId?: string;
}

interface ImportResult {
  serialNumber: string;
  importId?: string;
  status: 'Bereit' | 'Wird gesendet' | 'Ausstehend' | 'Abgeschlossen' | 'Fehler';
  detail?: string;
}

const app = document.querySelector<HTMLElement>('#app');
if (!app) throw new Error('Application root was not found.');

app.innerHTML = `
  <div class="shell">
    <header class="topbar">
      <a class="brand" href="./index.html" aria-label="Autopilot Import Startseite">
        <span class="brand-mark" aria-hidden="true">A</span>
        <span><strong>Autopilot</strong><small>Secure Import</small></span>
      </a>
      <div class="account-area">
        <span id="account-name" class="account-name"></span>
        <button id="logout" class="button button-quiet hidden" type="button">Abmelden</button>
      </div>
    </header>

    <section id="signin-view" class="hero">
      <div class="hero-copy">
        <span class="eyebrow">Windows-Geräte sicher bereitstellen</span>
        <h1>Autopilot-Import ohne lokale PowerShell-Abhängigkeit.</h1>
        <p>Melden Sie sich mit Ihrem Unternehmenskonto an. Berechtigungen und Group Tags werden serverseitig geprüft.</p>
        <button id="login" class="button button-primary" type="button">Mit Microsoft Entra ID anmelden</button>
      </div>
      <div class="security-card" aria-label="Sicherheitsmerkmale">
        <div class="security-icon" aria-hidden="true">✓</div>
        <h2>Geschützter Import</h2>
        <ul>
          <li>Keine Client Secrets im Browser</li>
          <li>Tag-Freigabe über Entra-Gruppen</li>
          <li>Graph-Zugriff nur per Managed Identity</li>
          <li>CSV-Verarbeitung lokal im Browser</li>
        </ul>
      </div>
    </section>

    <section id="workspace" class="workspace hidden">
      <div class="intro">
        <span class="eyebrow">Neuer Import</span>
        <h1>Geräte registrieren</h1>
        <p>CSV prüfen, autorisierten Tag auswählen und Import starten.</p>
      </div>

      <div id="alert" class="alert hidden" role="alert"></div>

      <div class="step-grid">
        <article class="panel">
          <div class="step-number">1</div>
          <div class="panel-heading">
            <h2>Autopilot CSV</h2>
            <p>Die Datei verbleibt im Browser und wird vor dem Import validiert.</p>
          </div>
          <label id="drop-zone" class="drop-zone" for="csv-file">
            <input id="csv-file" type="file" accept=".csv,text/csv" />
            <span class="upload-icon" aria-hidden="true">↑</span>
            <strong>CSV auswählen oder hier ablegen</strong>
            <span id="file-summary">Device Serial Number und Hardware Hash erforderlich</span>
          </label>
        </article>

        <article class="panel">
          <div class="step-number">2</div>
          <div class="panel-heading">
            <h2>Group Tag</h2>
            <p>Es werden nur Tags angezeigt, die für Ihre Entra-Gruppen freigegeben sind.</p>
          </div>
          <label class="field-label" for="group-tag">Autorisierter Tag</label>
          <select id="group-tag" disabled>
            <option value="">Tags werden geladen …</option>
          </select>
          <button id="start-import" class="button button-primary button-wide" type="button" disabled>Import starten</button>
        </article>
      </div>

      <section id="results-panel" class="panel results-panel hidden">
        <div class="results-header">
          <div>
            <span class="eyebrow">Importstatus</span>
            <h2 id="results-title">0 Geräte</h2>
          </div>
          <span id="progress-label" class="progress-label"></span>
        </div>
        <div class="progress-track" aria-hidden="true"><span id="progress-bar"></span></div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Seriennummer</th><th>Import-ID</th><th>Status</th><th>Details</th></tr></thead>
            <tbody id="results-body"></tbody>
          </table>
        </div>
      </section>
    </section>

    <footer>Intune Autopilot Import · Geschützt durch Microsoft Entra ID</footer>
  </div>
`;

function element<T extends HTMLElement>(id: string): T {
  const value = document.querySelector<T>(`#${id}`);
  if (!value) throw new Error(`Element #${id} was not found.`);
  return value;
}

const signinView = element<HTMLElement>('signin-view');
const workspace = element<HTMLElement>('workspace');
const loginButton = element<HTMLButtonElement>('login');
const logoutButton = element<HTMLButtonElement>('logout');
const accountName = element<HTMLElement>('account-name');
const fileInput = element<HTMLInputElement>('csv-file');
const fileSummary = element<HTMLElement>('file-summary');
const dropZone = element<HTMLElement>('drop-zone');
const tagSelect = element<HTMLSelectElement>('group-tag');
const importButton = element<HTMLButtonElement>('start-import');
const alertBox = element<HTMLElement>('alert');
const resultsPanel = element<HTMLElement>('results-panel');
const resultsTitle = element<HTMLElement>('results-title');
const resultsBody = element<HTMLTableSectionElement>('results-body');
const progressLabel = element<HTMLElement>('progress-label');
const progressBar = element<HTMLElement>('progress-bar');

let config: RuntimeConfig;
let msal: PublicClientApplication;
let account: AccountInfo | null = null;
let devices: AutopilotDevice[] = [];
let results: ImportResult[] = [];
let pollTimer: number | undefined;

function showAlert(message: string, kind: 'error' | 'success' = 'error'): void {
  alertBox.textContent = message;
  alertBox.className = `alert alert-${kind}`;
}

function clearAlert(): void {
  alertBox.textContent = '';
  alertBox.className = 'alert hidden';
}

function updateImportButton(): void {
  importButton.disabled = devices.length === 0 || !tagSelect.value || !account;
}

function updateResults(): void {
  resultsBody.replaceChildren(...results.map((result) => {
    const row = document.createElement('tr');
    const statusClass = result.status === 'Fehler'
      ? 'status-error'
      : result.status === 'Abgeschlossen'
        ? 'status-complete'
        : 'status-pending';
    for (const value of [result.serialNumber, result.importId ?? '—']) {
      const cell = document.createElement('td');
      cell.textContent = value;
      row.append(cell);
    }
    const statusCell = document.createElement('td');
    const badge = document.createElement('span');
    badge.className = `status ${statusClass}`;
    badge.textContent = result.status;
    statusCell.append(badge);
    row.append(statusCell);
    const detailCell = document.createElement('td');
    detailCell.textContent = result.detail ?? '—';
    row.append(detailCell);
    return row;
  }));

  const finished = results.filter((item) => item.status === 'Abgeschlossen' || item.status === 'Fehler').length;
  resultsTitle.textContent = `${results.length} ${results.length === 1 ? 'Gerät' : 'Geräte'}`;
  progressLabel.textContent = `${finished} von ${results.length} abgeschlossen`;
  progressBar.style.width = results.length === 0 ? '0%' : `${Math.round((finished / results.length) * 100)}%`;
}

async function apiRequest<T>(url: string, init?: RequestInit): Promise<T> {
  if (!account) throw new Error('Anmeldung erforderlich.');
  let token;
  try {
    token = await msal.acquireTokenSilent({ account, scopes: [config.scope] });
  } catch (error) {
    if (!(error instanceof InteractionRequiredAuthError)) throw error;
    token = await msal.acquireTokenPopup({ account, scopes: [config.scope] });
  }

  const response = await fetch(url, {
    ...init,
    headers: {
      ...init?.headers,
      Authorization: `Bearer ${token.accessToken}`,
      'Content-Type': 'application/json',
    },
  });
  const body = await response.json() as T & ApiError;
  if (!response.ok) {
    const detail = body.message ?? body.error ?? `HTTP ${response.status}`;
    const correlation = body.correlationId ? ` Correlation ID: ${body.correlationId}.` : '';
    throw new Error(`${detail}.${correlation}`);
  }
  return body;
}

async function loadTags(): Promise<void> {
  const response = await apiRequest<{ tags: string[] }>(config.tagsUrl);
  tagSelect.replaceChildren();
  const placeholder = document.createElement('option');
  placeholder.value = '';
  placeholder.textContent = response.tags.length > 0 ? 'Tag auswählen' : 'Keine Tags zugewiesen';
  tagSelect.append(placeholder);
  for (const tag of response.tags) {
    const option = document.createElement('option');
    option.value = tag;
    option.textContent = tag;
    tagSelect.append(option);
  }
  tagSelect.disabled = response.tags.length === 0;
  updateImportButton();
  if (response.tags.length === 0) showAlert('Für Ihr Konto ist kein Group Tag freigegeben.');
}

async function setAuthenticatedView(selectedAccount: AccountInfo): Promise<void> {
  account = selectedAccount;
  msal.setActiveAccount(account);
  accountName.textContent = account.name ?? account.username;
  logoutButton.classList.remove('hidden');
  signinView.classList.add('hidden');
  workspace.classList.remove('hidden');
  try {
    await loadTags();
  } catch (error) {
    showAlert(error instanceof Error ? error.message : 'Tags konnten nicht geladen werden.');
  }
}

async function readFile(file: File): Promise<void> {
  clearAlert();
  try {
    devices = parseAutopilotCsv(await file.text());
    fileSummary.textContent = `${file.name} · ${devices.length} ${devices.length === 1 ? 'Gerät' : 'Geräte'} geprüft`;
    dropZone.classList.add('drop-zone-valid');
  } catch (error) {
    devices = [];
    dropZone.classList.remove('drop-zone-valid');
    fileSummary.textContent = 'Device Serial Number und Hardware Hash erforderlich';
    showAlert(error instanceof Error ? error.message : 'CSV konnte nicht validiert werden.');
  }
  updateImportButton();
}

async function importDevice(index: number, groupTag: string): Promise<void> {
  const device = devices[index];
  if (!device) return;
  results[index] = { serialNumber: device.serialNumber, status: 'Wird gesendet' };
  updateResults();
  try {
    const response = await apiRequest<{ importId: string; status: string }>(config.importUrl, {
      method: 'POST',
      body: JSON.stringify({ ...device, groupTag }),
    });
    results[index] = {
      serialNumber: device.serialNumber,
      importId: response.importId,
      status: 'Ausstehend',
      detail: response.status,
    };
  } catch (error) {
    results[index] = {
      serialNumber: device.serialNumber,
      status: 'Fehler',
      detail: error instanceof Error ? error.message : 'Import fehlgeschlagen.',
    };
  }
  updateResults();
}

async function pollResults(): Promise<void> {
  const pending = results.filter((item) => item.importId && item.status === 'Ausstehend');
  await Promise.all(pending.map(async (item) => {
    try {
      const status = await apiRequest<{
        workflowStatus: string;
        status: string;
        deviceErrorName?: string;
      }>(`${config.importUrl}?importId=${encodeURIComponent(item.importId ?? '')}`);
      if (status.workflowStatus === 'complete') {
        item.status = 'Abgeschlossen';
        item.detail = 'Intune-Import und Geräteattribut abgeschlossen';
      } else if (status.workflowStatus === 'error') {
        item.status = 'Fehler';
        item.detail = status.deviceErrorName ?? status.status;
      } else {
        item.detail = status.status;
      }
    } catch (error) {
      item.detail = error instanceof Error ? error.message : 'Statusabfrage fehlgeschlagen.';
    }
  }));
  updateResults();
  if (results.every((item) => item.status === 'Abgeschlossen' || item.status === 'Fehler')) {
    if (pollTimer !== undefined) window.clearInterval(pollTimer);
    pollTimer = undefined;
    showAlert('Alle Importvorgänge wurden verarbeitet.', 'success');
  }
}

loginButton.addEventListener('click', () => {
  void msal.loginRedirect({ scopes: [config.scope], redirectUri: config.redirectUri });
});
logoutButton.addEventListener('click', () => {
  void msal.logoutRedirect({ account: account ?? undefined, postLogoutRedirectUri: config.redirectUri });
});
tagSelect.addEventListener('change', updateImportButton);
fileInput.addEventListener('change', () => {
  const file = fileInput.files?.[0];
  if (file) void readFile(file);
});
for (const eventName of ['dragenter', 'dragover']) {
  dropZone.addEventListener(eventName, (event) => {
    event.preventDefault();
    dropZone.classList.add('drop-zone-active');
  });
}
for (const eventName of ['dragleave', 'drop']) {
  dropZone.addEventListener(eventName, (event) => {
    event.preventDefault();
    dropZone.classList.remove('drop-zone-active');
  });
}
dropZone.addEventListener('drop', (event) => {
  const file = event.dataTransfer?.files[0];
  if (file) void readFile(file);
});
importButton.addEventListener('click', async () => {
  const groupTag = tagSelect.value;
  if (!groupTag || devices.length === 0) return;
  clearAlert();
  importButton.disabled = true;
  resultsPanel.classList.remove('hidden');
  results = devices.map((device) => ({ serialNumber: device.serialNumber, status: 'Bereit' }));
  updateResults();

  let nextIndex = 0;
  const worker = async (): Promise<void> => {
    while (nextIndex < devices.length) {
      const index = nextIndex++;
      await importDevice(index, groupTag);
    }
  };
  await Promise.all(Array.from({ length: Math.min(3, devices.length) }, worker));
  await pollResults();
  if (results.some((item) => item.status === 'Ausstehend')) {
    pollTimer = window.setInterval(() => void pollResults(), 15_000);
  }
  updateImportButton();
});

async function initialize(): Promise<void> {
  try {
    const configResponse = await fetch('./config', { cache: 'no-store' });
    if (!configResponse.ok) throw new Error('Web-Frontend ist nicht vollständig konfiguriert.');
    config = await configResponse.json() as RuntimeConfig;
    msal = new PublicClientApplication({
      auth: {
        clientId: config.clientId,
        authority: config.authority,
        redirectUri: config.redirectUri,
      },
      cache: { cacheLocation: 'sessionStorage' },
    });
    await msal.initialize();
    const redirectResult = await msal.handleRedirectPromise();
    const selectedAccount = redirectResult?.account ?? msal.getAllAccounts()[0];
    if (selectedAccount) await setAuthenticatedView(selectedAccount);
  } catch (error) {
    signinView.classList.add('hidden');
    workspace.classList.remove('hidden');
    showAlert(error instanceof Error ? error.message : 'Anwendung konnte nicht initialisiert werden.');
  }
}

void initialize();
