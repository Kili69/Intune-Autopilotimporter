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
  status: 'ready' | 'sending' | 'pending' | 'complete' | 'error';
  detail?: string;
}

type Language = 'de' | 'en';

const translations = {
  de: {
    homeLabel: 'Autopilot Import Startseite', logout: 'Abmelden', intro: 'Melden Sie sich mit Ihrem Unternehmenskonto an. Berechtigungen und Group Tags werden serverseitig geprüft.',
    login: 'Mit Microsoft Entra ID anmelden', hashLabel: 'Device Hash erstellen', hashIntro: 'Auf dem Zielgerät während der Windows-Ersteinrichtung:',
    hashStep1: 'Mit Umschalt + F10 die Eingabeaufforderung öffnen', hashStep2: 'powershell.exe starten', hashStep3: 'Install-Script Get-WindowsAutopilotInfo -Force ausführen',
    hashStep4: 'Get-WindowsAutopilotInfo -OutputFile D:\\AutopilotHWID.csv ausführen', hashNote: 'Den Laufwerksbuchstaben bei Bedarf an den USB-Stick anpassen.',
    newImport: 'Neuer Import', register: 'Geräte registrieren', registerIntro: 'CSV prüfen, autorisierten Tag auswählen und Import starten.',
    csvHelp: 'Die Datei verbleibt im Browser und wird vor dem Import validiert.', csvSelect: 'CSV auswählen oder hier ablegen', csvRequirements: 'Device Serial Number und Hardware Hash erforderlich',
    tagHelp: 'Es werden nur Tags angezeigt, die für Ihre Entra-Gruppen freigegeben sind.', authorizedTag: 'Autorisierter Tag', loadingTags: 'Tags werden geladen …', startImport: 'Import starten',
    importStatus: 'Importstatus', devicesZero: '0 Geräte', serialNumber: 'Seriennummer', importId: 'Import-ID', status: 'Status', details: 'Details',
    footer: 'Intune Autopilot Import · Geschützt durch Microsoft Entra ID', statusReady: 'Bereit', statusSending: 'Wird gesendet', statusPending: 'Ausstehend', statusComplete: 'Abgeschlossen', statusError: 'Fehler',
    signInRequired: 'Anmeldung erforderlich.', selectTag: 'Tag auswählen', noTags: 'Keine Tags zugewiesen', noTagsForAccount: 'Für Ihr Konto ist kein Group Tag freigegeben.',
    device: 'Gerät', devices: 'Geräte', checked: 'geprüft', tagsLoadFailed: 'Tags konnten nicht geladen werden.', csvValidationFailed: 'CSV konnte nicht validiert werden.',
    importFailed: 'Import fehlgeschlagen.', completedDetail: 'Intune-Import und Geräteattribut abgeschlossen', statusFailed: 'Statusabfrage fehlgeschlagen.',
    processed: 'Alle Importvorgänge wurden verarbeitet.', completedOf: 'abgeschlossen', frontendNotConfigured: 'Web-Frontend ist nicht vollständig konfiguriert.', initializationFailed: 'Anwendung konnte nicht initialisiert werden.',
  },
  en: {
    homeLabel: 'Autopilot Import home', logout: 'Sign out', intro: 'Sign in with your organizational account. Permissions and Group Tags are validated on the server.',
    login: 'Sign in with Microsoft Entra ID', hashLabel: 'Create a device hash', hashIntro: 'On the target device during Windows setup:',
    hashStep1: 'Press Shift + F10 to open Command Prompt', hashStep2: 'Start powershell.exe', hashStep3: 'Run Install-Script Get-WindowsAutopilotInfo -Force',
    hashStep4: 'Run Get-WindowsAutopilotInfo -OutputFile D:\\AutopilotHWID.csv', hashNote: 'Change the drive letter to match the USB drive if necessary.',
    newImport: 'New import', register: 'Register devices', registerIntro: 'Validate the CSV, select an authorized tag, and start the import.',
    csvHelp: 'The file remains in the browser and is validated before import.', csvSelect: 'Select a CSV or drop it here', csvRequirements: 'Device Serial Number and Hardware Hash are required',
    tagHelp: 'Only tags authorized for your Entra groups are displayed.', authorizedTag: 'Authorized tag', loadingTags: 'Loading tags …', startImport: 'Start import',
    importStatus: 'Import status', devicesZero: '0 devices', serialNumber: 'Serial number', importId: 'Import ID', status: 'Status', details: 'Details',
    footer: 'Intune Autopilot Import · Protected by Microsoft Entra ID', statusReady: 'Ready', statusSending: 'Sending', statusPending: 'Pending', statusComplete: 'Complete', statusError: 'Error',
    signInRequired: 'Sign-in required.', selectTag: 'Select a tag', noTags: 'No tags assigned', noTagsForAccount: 'No Group Tag is authorized for your account.',
    device: 'device', devices: 'devices', checked: 'validated', tagsLoadFailed: 'Tags could not be loaded.', csvValidationFailed: 'The CSV could not be validated.',
    importFailed: 'Import failed.', completedDetail: 'Intune import and device attribute completed', statusFailed: 'Status request failed.',
    processed: 'All import operations have been processed.', completedOf: 'complete', frontendNotConfigured: 'The web frontend is not fully configured.', initializationFailed: 'The application could not be initialized.',
  },
} as const;

type TranslationKey = keyof typeof translations.de;
const savedLanguage = localStorage.getItem('autopilot-language');
const language: Language = savedLanguage === 'de' || savedLanguage === 'en'
  ? savedLanguage
  : navigator.language.toLowerCase().startsWith('de') ? 'de' : 'en';
const t = (key: TranslationKey): string => translations[language][key];
document.documentElement.lang = language;

const app = document.querySelector<HTMLElement>('#app');
if (!app) throw new Error('Application root was not found.');

app.innerHTML = `
  <div class="shell">
    <header class="topbar">
      <a class="brand" href="./index.html" aria-label="${t('homeLabel')}">
        <span class="brand-mark" aria-hidden="true">A</span>
        <span><strong>Autopilot</strong><small>Secure Import</small></span>
      </a>
      <div class="account-area">
        <div class="language-switch" aria-label="Language / Sprache">
          <button type="button" data-language="de" aria-pressed="${language === 'de'}">DE</button>
          <button type="button" data-language="en" aria-pressed="${language === 'en'}">EN</button>
        </div>
        <span id="account-name" class="account-name"></span>
        <button id="logout" class="button button-quiet hidden" type="button">${t('logout')}</button>
      </div>
    </header>

    <section id="signin-view" class="hero">
      <div class="hero-copy">
        <h1>Intune Autopilot Device Importer</h1>
        <p>${t('intro')}</p>
        <button id="login" class="button button-primary" type="button">${t('login')}</button>
      </div>
      <div class="security-card" aria-label="${t('hashLabel')}">
        <div class="security-icon" aria-hidden="true">#</div>
        <h2>${t('hashLabel')}</h2>
        <p class="device-hash-intro">${t('hashIntro')}</p>
        <ul>
          <li>${t('hashStep1')}</li>
          <li>${t('hashStep2')}</li>
          <li>${t('hashStep3')}</li>
          <li>${t('hashStep4')}</li>
        </ul>
        <p class="device-hash-note">${t('hashNote')}</p>
      </div>
    </section>

    <section id="workspace" class="workspace hidden">
      <div class="intro">
        <span class="eyebrow">${t('newImport')}</span>
        <h1>${t('register')}</h1>
        <p>${t('registerIntro')}</p>
      </div>

      <div id="alert" class="alert hidden" role="alert"></div>

      <div class="step-grid">
        <article class="panel">
          <div class="step-number">1</div>
          <div class="panel-heading">
            <h2>Autopilot CSV</h2>
            <p>${t('csvHelp')}</p>
          </div>
          <label id="drop-zone" class="drop-zone" for="csv-file">
            <input id="csv-file" type="file" accept=".csv,text/csv" />
            <span class="upload-icon" aria-hidden="true">↑</span>
            <strong>${t('csvSelect')}</strong>
            <span id="file-summary">${t('csvRequirements')}</span>
          </label>
        </article>

        <article class="panel">
          <div class="step-number">2</div>
          <div class="panel-heading">
            <h2>Group Tag</h2>
            <p>${t('tagHelp')}</p>
          </div>
          <label class="field-label" for="group-tag">${t('authorizedTag')}</label>
          <select id="group-tag" disabled>
            <option value="">${t('loadingTags')}</option>
          </select>
          <button id="start-import" class="button button-primary button-wide" type="button" disabled>${t('startImport')}</button>
        </article>
      </div>

      <section id="results-panel" class="panel results-panel hidden">
        <div class="results-header">
          <div>
            <span class="eyebrow">${t('importStatus')}</span>
            <h2 id="results-title">${t('devicesZero')}</h2>
          </div>
          <span id="progress-label" class="progress-label"></span>
        </div>
        <div class="progress-track" aria-hidden="true"><span id="progress-bar"></span></div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>${t('serialNumber')}</th><th>${t('importId')}</th><th>${t('status')}</th><th>${t('details')}</th></tr></thead>
            <tbody id="results-body"></tbody>
          </table>
        </div>
      </section>
    </section>

    <footer>${t('footer')}</footer>
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

document.querySelectorAll<HTMLButtonElement>('[data-language]').forEach((button) => {
  button.addEventListener('click', () => {
    const selectedLanguage = button.dataset.language;
    if (selectedLanguage !== 'de' && selectedLanguage !== 'en') return;
    localStorage.setItem('autopilot-language', selectedLanguage);
    window.location.reload();
  });
});

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
    const statusClass = result.status === 'error'
      ? 'status-error'
      : result.status === 'complete'
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
    const statusKeys: Record<ImportResult['status'], TranslationKey> = {
      ready: 'statusReady', sending: 'statusSending', pending: 'statusPending', complete: 'statusComplete', error: 'statusError',
    };
    badge.textContent = t(statusKeys[result.status]);
    statusCell.append(badge);
    row.append(statusCell);
    const detailCell = document.createElement('td');
    detailCell.textContent = result.detail ?? '—';
    row.append(detailCell);
    return row;
  }));

  const finished = results.filter((item) => item.status === 'complete' || item.status === 'error').length;
  resultsTitle.textContent = `${results.length} ${results.length === 1 ? t('device') : t('devices')}`;
  progressLabel.textContent = language === 'de'
    ? `${finished} von ${results.length} ${t('completedOf')}`
    : `${finished} of ${results.length} ${t('completedOf')}`;
  progressBar.style.width = results.length === 0 ? '0%' : `${Math.round((finished / results.length) * 100)}%`;
}

async function apiRequest<T>(url: string, init?: RequestInit): Promise<T> {
  if (!account) throw new Error(t('signInRequired'));
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
  placeholder.textContent = response.tags.length > 0 ? t('selectTag') : t('noTags');
  tagSelect.append(placeholder);
  for (const tag of response.tags) {
    const option = document.createElement('option');
    option.value = tag;
    option.textContent = tag;
    tagSelect.append(option);
  }
  tagSelect.disabled = response.tags.length === 0;
  updateImportButton();
  if (response.tags.length === 0) showAlert(t('noTagsForAccount'));
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
    showAlert(error instanceof Error ? error.message : t('tagsLoadFailed'));
  }
}

async function readFile(file: File): Promise<void> {
  clearAlert();
  try {
    devices = parseAutopilotCsv(await file.text());
    fileSummary.textContent = `${file.name} · ${devices.length} ${devices.length === 1 ? t('device') : t('devices')} ${t('checked')}`;
    dropZone.classList.add('drop-zone-valid');
  } catch (error) {
    devices = [];
    dropZone.classList.remove('drop-zone-valid');
    fileSummary.textContent = t('csvRequirements');
    showAlert(error instanceof Error ? error.message : t('csvValidationFailed'));
  }
  updateImportButton();
}

async function importDevice(index: number, groupTag: string): Promise<void> {
  const device = devices[index];
  if (!device) return;
  results[index] = { serialNumber: device.serialNumber, status: 'sending' };
  updateResults();
  try {
    const response = await apiRequest<{ importId: string; status: string }>(config.importUrl, {
      method: 'POST',
      body: JSON.stringify({ ...device, groupTag }),
    });
    results[index] = {
      serialNumber: device.serialNumber,
      importId: response.importId,
      status: 'pending',
      detail: response.status,
    };
  } catch (error) {
    results[index] = {
      serialNumber: device.serialNumber,
      status: 'error',
      detail: error instanceof Error ? error.message : t('importFailed'),
    };
  }
  updateResults();
}

async function pollResults(): Promise<void> {
  const pending = results.filter((item) => item.importId && item.status === 'pending');
  await Promise.all(pending.map(async (item) => {
    try {
      const status = await apiRequest<{
        workflowStatus: string;
        status: string;
        deviceErrorName?: string;
      }>(`${config.importUrl}?importId=${encodeURIComponent(item.importId ?? '')}`);
      if (status.workflowStatus === 'complete') {
        item.status = 'complete';
        item.detail = t('completedDetail');
      } else if (status.workflowStatus === 'error') {
        item.status = 'error';
        item.detail = status.deviceErrorName ?? status.status;
      } else {
        item.detail = status.status;
      }
    } catch (error) {
      item.detail = error instanceof Error ? error.message : t('statusFailed');
    }
  }));
  updateResults();
  if (results.every((item) => item.status === 'complete' || item.status === 'error')) {
    if (pollTimer !== undefined) window.clearInterval(pollTimer);
    pollTimer = undefined;
    showAlert(t('processed'), 'success');
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
  results = devices.map((device) => ({ serialNumber: device.serialNumber, status: 'ready' }));
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
  if (results.some((item) => item.status === 'pending')) {
    pollTimer = window.setInterval(() => void pollResults(), 15_000);
  }
  updateImportButton();
});

async function initialize(): Promise<void> {
  try {
    const configResponse = await fetch('./config', { cache: 'no-store' });
    if (!configResponse.ok) throw new Error(t('frontendNotConfigured'));
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
    showAlert(error instanceof Error ? error.message : t('initializationFailed'));
  }
}

void initialize();
