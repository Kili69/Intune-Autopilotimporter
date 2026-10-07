import {
  AccountInfo,
  AuthenticationResult,
  BrowserAuthError,
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
  silentRedirectUri: string;
  importUrl: string;
  tagsUrl: string;
  deviceTagAssignmentsUrl: string;
  importHistoryUrl: string;
}

interface ApiError {
  error?: string;
  message?: string;
  correlationId?: string;
}

interface ImportResult {
  serialNumber: string;
  operationId?: string;
  operationType: 'import' | 'tagChange';
  status: 'ready' | 'sending' | 'pending' | 'complete' | 'error';
  detail?: string;
}

interface ExistingAutopilotDevice {
  id: string;
  serialNumber: string;
  groupTag: string;
  groups: string[];
  administrativeUnits: string[];
}

interface ImportHistoryRecord {
  importId?: string;
  operationType?: string;
  serialNumber?: string;
  groupTag?: string;
  previousGroupTag?: string;
  status?: string;
  requestedBy?: string;
  requestedByDisplayName?: string;
  deviceErrorName?: string;
  requestReceivedAtUtc?: string;
  graphImportCreatedAtUtc?: string;
  queuedAtUtc?: string;
  processingStartedAtUtc?: string;
  entraDeviceResolvedAtUtc?: string;
  autopilotGroupTagUpdatedAtUtc?: string;
  extensionAttributeUpdatedAtUtc?: string;
  administrativeUnitAssignedAtUtc?: string;
  processingCompletedAtUtc?: string;
  lastUpdatedAtUtc?: string;
}

type Language = 'de' | 'en';

const translations = {
  de: {
    homeLabel: 'Autopilot Import Startseite', brandSubtitle: 'Device Hash Import', logout: 'Abmelden', intro: 'Melden Sie sich mit Ihrem Unternehmenskonto an. Berechtigungen und Group Tags werden serverseitig geprüft.',
    login: 'Mit Microsoft Entra ID anmelden', hashLabel: 'Device Hash erstellen', hashIntro: 'Auf dem Zielgerät während der Windows-Ersteinrichtung:',
    hashStep1: 'Mit Umschalt + F10 die Eingabeaufforderung öffnen', hashStep2: 'powershell.exe starten', hashStep3: 'Install-Script Get-WindowsAutopilotInfo -Force ausführen',
    hashStep4: 'Get-WindowsAutopilotInfo -OutputFile D:\\AutopilotHWID.csv ausführen', hashNote: 'Den Laufwerksbuchstaben bei Bedarf an den USB-Stick anpassen.',
    register: 'Geräte in Microsoft Intune registrieren', registerIntro: 'CSV prüfen, autorisierten Tag auswählen und Import starten.',
    csvHelp: 'Die Datei verbleibt im Browser und wird vor dem Import validiert.', csvSelect: 'CSV auswählen oder hier ablegen', csvRequirements: 'Device Serial Number und Hardware Hash erforderlich',
    tagHelp: 'Es werden nur Tags angezeigt, die für Ihre Entra-Gruppen freigegeben sind.', authorizedTag: 'Autorisierter Tag', loadingTags: 'Tags werden geladen …', startImport: 'Import starten',
    importStatus: 'Verarbeitungsstatus', devicesZero: '0 Geräte', serialNumber: 'Seriennummer', operationId: 'Vorgangs-ID', status: 'Status', details: 'Details',
    historyTitle: 'Importverlauf', historyScopeSelf: 'Nur eigene Imports', historyScopeAll: 'Alle sichtbaren Imports', requestedBy: 'Angefordert von',
    footer: 'Intune Autopilot Import · Geschützt durch Microsoft Entra ID', author: 'Autor: Andreas Lucas (Kili)', license: 'Apache License 2.0', statusReady: 'Bereit', statusSending: 'Wird gesendet', statusPending: 'Ausstehend', statusComplete: 'Abgeschlossen', statusError: 'Fehler',
    signInRequired: 'Anmeldung erforderlich.', selectTag: 'Tag auswählen', noTags: 'Keine Tags zugewiesen', noTagsForAccount: 'Für Ihr Konto ist kein Group Tag freigegeben.',
    device: 'Gerät', devices: 'Geräte', checked: 'geprüft', tagsLoadFailed: 'Tags konnten nicht geladen werden.', csvValidationFailed: 'CSV konnte nicht validiert werden.',
    importFailed: 'Import fehlgeschlagen.', completedDetail: 'Intune-Import und Geräteattribut abgeschlossen', statusFailed: 'Statusabfrage fehlgeschlagen.',
    completedOf: 'abgeschlossen', frontendNotConfigured: 'Web-Frontend ist nicht vollständig konfiguriert.', initializationFailed: 'Anwendung konnte nicht initialisiert werden.',
    changeTagsTitle: 'Group Tags vorhandener Geräte ändern', changeTagsIntro: 'Noch nicht installierte Geräte aus Ihren Vorhaben auswählen und gemeinsam einem neuen Tag zuordnen.',
    selectAll: 'Alle auswählen', currentTag: 'Aktueller Tag / OrderID', currentGroups: 'Aktuelle Gruppen', administrativeUnits: 'Administrative Unit',
    noEligibleDevices: 'Keine noch nicht installierten Geräte in Ihren Vorhaben gefunden.', targetTag: 'Neuer autorisierter Tag', startTagChange: 'Tag ändern',
    devicesLoadFailed: 'Geräte konnten nicht geladen werden.', tagChangeFailed: 'Tag konnte nicht geändert werden.',
    importTab: 'Import', retagTab: 'Re-Tagging',
    lastUpdated: 'Letzte Aktualisierung', traceTitle: 'Vorgangsverlauf', close: 'Schließen', traceCurrentStatus: 'Aktueller Status',
    traceRequested: 'Anfrage wurde entgegengenommen', traceCreatedInIntune: 'Gerät wurde an Intune übermittelt', traceQueued: 'Nachbearbeitung wurde eingeplant',
    traceStarted: 'Nachbearbeitung wurde gestartet', traceDeviceResolved: 'Entra-Gerät wurde gefunden', traceAutopilotTagUpdated: 'Autopilot Group Tag wurde aktualisiert',
    traceAttributeUpdated: 'Geräteattribut wurde aktualisiert', traceAuUpdated: 'Administrative Unit wurde aktualisiert', traceCompleted: 'Vorgang wurde abgeschlossen',
    traceError: 'Fehler', groupTagLabel: 'Group Tag', previousGroupTagLabel: 'Vorheriger Group Tag', traceOpen: 'Vorgangsverlauf öffnen',
  },
  en: {
    homeLabel: 'Autopilot Import home', brandSubtitle: 'Device Hash Import', logout: 'Sign out', intro: 'Sign in with your organizational account. Permissions and Group Tags are validated on the server.',
    login: 'Sign in with Microsoft Entra ID', hashLabel: 'Create a device hash', hashIntro: 'On the target device during Windows setup:',
    hashStep1: 'Press Shift + F10 to open Command Prompt', hashStep2: 'Start powershell.exe', hashStep3: 'Run Install-Script Get-WindowsAutopilotInfo -Force',
    hashStep4: 'Run Get-WindowsAutopilotInfo -OutputFile D:\\AutopilotHWID.csv', hashNote: 'Change the drive letter to match the USB drive if necessary.',
    register: 'Register devices in Microsoft Intune', registerIntro: 'Validate the CSV, select an authorized tag, and start the import.',
    csvHelp: 'The file remains in the browser and is validated before import.', csvSelect: 'Select a CSV or drop it here', csvRequirements: 'Device Serial Number and Hardware Hash are required',
    tagHelp: 'Only tags authorized for your Entra groups are displayed.', authorizedTag: 'Device and Intune Group Tag', loadingTags: 'Loading tags …', startImport: 'Start import',
    importStatus: 'Processing status', devicesZero: '0 devices', serialNumber: 'Serial number', operationId: 'Operation ID', status: 'Status', details: 'Details',
    historyTitle: 'Import history', historyScopeSelf: 'My imports only', historyScopeAll: 'All visible imports', requestedBy: 'Requested by',
    footer: 'Intune Autopilot Import · Protected by Microsoft Entra ID', author: 'Author: Andreas Lucas (Kili)', license: 'Apache License 2.0', statusReady: 'Ready', statusSending: 'Sending', statusPending: 'Pending', statusComplete: 'Complete', statusError: 'Error',
    signInRequired: 'Sign-in required.', selectTag: 'Select a tag', noTags: 'No tags assigned', noTagsForAccount: 'No Group Tag is authorized for your account.',
    device: 'device', devices: 'devices', checked: 'validated', tagsLoadFailed: 'Tags could not be loaded.', csvValidationFailed: 'The CSV could not be validated.',
    importFailed: 'Import failed.', completedDetail: 'Intune import and device attribute completed', statusFailed: 'Status request failed.',
    completedOf: 'complete', frontendNotConfigured: 'The web frontend is not fully configured.', initializationFailed: 'The application could not be initialized.',
    changeTagsTitle: 'Change Group Tags for existing devices', changeTagsIntro: 'Select devices that have not been installed from your projects and assign a new tag to them.',
    selectAll: 'Select all', currentTag: 'Current tag / OrderID', currentGroups: 'Current groups', administrativeUnits: 'Administrative unit',
    noEligibleDevices: 'No uninstalled devices were found in your projects.', targetTag: 'New authorized tag', startTagChange: 'Change tag',
    devicesLoadFailed: 'Devices could not be loaded.', tagChangeFailed: 'The tag could not be changed.',
    importTab: 'Import', retagTab: 'Re-tagging',
    lastUpdated: 'Last updated', traceTitle: 'Operation trace', close: 'Close', traceCurrentStatus: 'Current status',
    traceRequested: 'Request was received', traceCreatedInIntune: 'Device was submitted to Intune', traceQueued: 'Post-processing was queued',
    traceStarted: 'Post-processing started', traceDeviceResolved: 'Entra device was resolved', traceAutopilotTagUpdated: 'Autopilot Group Tag was updated',
    traceAttributeUpdated: 'Device attribute was updated', traceAuUpdated: 'Administrative unit was updated', traceCompleted: 'Operation completed',
    traceError: 'Error', groupTagLabel: 'Group Tag', previousGroupTagLabel: 'Previous Group Tag', traceOpen: 'Open operation trace',
  },
} as const;

type TranslationKey = keyof typeof translations.de;
declare const __APP_VERSION__: string;

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
        <span><strong>Autopilot</strong><small>${t('brandSubtitle')}</small></span>
      </a>
      <div class="account-area">
        <div class="language-switch" aria-label="Language / Sprache">
          <button type="button" data-language="de" aria-pressed="${language === 'de'}">DE</button>
          <button type="button" data-language="en" aria-pressed="${language === 'en'}">EN</button>
        </div>
        <span class="account-identity">
          <span id="account-name" class="account-name"></span>
          <span id="account-upn" class="account-upn"></span>
        </span>
        <button id="logout" class="button button-quiet hidden" type="button">${t('logout')}</button>
        <img class="header-logo" src="/api/ui/kjitlogo.png" alt="Intune Autopilot Importer logo">
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
        <h1>${t('register')}</h1>
        <p>${t('registerIntro')}</p>
      </div>

      <div id="alert" class="alert hidden" role="alert"></div>

      <div class="workspace-tabs" role="tablist" aria-label="${t('register')}">
        <button id="import-tab" class="workspace-tab" type="button" role="tab" aria-selected="true" aria-controls="import-tab-panel">${t('importTab')}</button>
        <button id="retag-tab" class="workspace-tab" type="button" role="tab" aria-selected="false" aria-controls="retag-tab-panel" tabindex="-1">${t('retagTab')}</button>
      </div>

      <div id="import-tab-panel" class="tab-panel" role="tabpanel" aria-labelledby="import-tab">
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
      </div>

      <div id="retag-tab-panel" class="tab-panel hidden" role="tabpanel" aria-labelledby="retag-tab">
        <section class="panel">
          <div class="results-header">
            <div>
              <span class="eyebrow">Autopilot</span>
              <h2>${t('changeTagsTitle')}</h2>
              <p class="section-intro">${t('changeTagsIntro')}</p>
            </div>
            <span id="device-count" class="progress-label"></span>
          </div>
          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th class="selection-cell"><input id="select-all-devices" type="checkbox" aria-label="${t('selectAll')}"></th>
                  <th>${t('serialNumber')}</th>
                  <th>${t('currentTag')}</th>
                  <th>${t('currentGroups')}</th>
                  <th>${t('administrativeUnits')}</th>
                </tr>
              </thead>
              <tbody id="existing-devices-body"></tbody>
            </table>
          </div>
          <p id="no-existing-devices" class="empty-state hidden">${t('noEligibleDevices')}</p>
          <div class="tag-change-actions">
            <label class="field-label" for="new-group-tag">${t('targetTag')}</label>
            <select id="new-group-tag" disabled>
              <option value="">${t('loadingTags')}</option>
            </select>
            <button id="start-tag-change" class="button button-primary" type="button" disabled>${t('startTagChange')}</button>
          </div>
        </section>
      </div>

      <section class="panel results-panel">
        <section id="results-panel" class="activity-section hidden">
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
              <thead><tr><th>${t('serialNumber')}</th><th>${t('operationId')}</th><th>${t('status')}</th><th>${t('details')}</th></tr></thead>
              <tbody id="results-body"></tbody>
            </table>
          </div>
        </section>

        <section id="history-panel" class="activity-section">
          <div class="results-header">
            <div>
              <span class="eyebrow">${t('importStatus')}</span>
              <h2>${t('historyTitle')}</h2>
            </div>
            <span id="history-scope" class="progress-label">${t('historyScopeSelf')}</span>
          </div>
          <div class="table-wrap">
            <table>
              <thead><tr><th>${t('lastUpdated')}</th><th>${t('serialNumber')}</th><th>${t('status')}</th><th>${t('requestedBy')}</th></tr></thead>
              <tbody id="history-body"></tbody>
            </table>
          </div>
        </section>
      </section>

      <dialog id="history-trace-dialog" class="trace-dialog" aria-labelledby="trace-dialog-title">
        <div class="trace-dialog-header">
          <div>
            <span class="eyebrow">${t('importStatus')}</span>
            <h2 id="trace-dialog-title">${t('traceTitle')}</h2>
          </div>
          <button id="close-trace-dialog" class="button button-quiet" type="button">${t('close')}</button>
        </div>
        <div id="trace-summary" class="trace-summary"></div>
        <ol id="trace-steps" class="trace-steps"></ol>
      </dialog>
    </section>

    <footer>
      <span>${t('footer')}</span>
      <span aria-hidden="true">·</span>
      <a href="mailto:andreas.lucas@outlook.com">${t('author')}</a>
      <span aria-hidden="true">·</span>
      <a href="https://github.com/Kili69/Intune-Autopilotimporter/blob/dev/LICENSE" target="_blank" rel="noopener noreferrer">${t('license')}</a>
      <span aria-hidden="true">·</span>
      <span>v${__APP_VERSION__}</span>
    </footer>
  </div>
`;

function element<T extends HTMLElement>(id: string): T {
  const value = document.querySelector<T>(`#${id}`);
  if (!value) throw new Error(`Element #${id} was not found.`);
  return value;
}

const signinView = element<HTMLElement>('signin-view');
const workspace = element<HTMLElement>('workspace');
const importTab = element<HTMLButtonElement>('import-tab');
const retagTab = element<HTMLButtonElement>('retag-tab');
const importTabPanel = element<HTMLElement>('import-tab-panel');
const retagTabPanel = element<HTMLElement>('retag-tab-panel');
const loginButton = element<HTMLButtonElement>('login');
const logoutButton = element<HTMLButtonElement>('logout');
const accountName = element<HTMLElement>('account-name');
const accountUpn = element<HTMLElement>('account-upn');
const fileInput = element<HTMLInputElement>('csv-file');
const fileSummary = element<HTMLElement>('file-summary');
const dropZone = element<HTMLElement>('drop-zone');
const tagSelect = element<HTMLSelectElement>('group-tag');
const importButton = element<HTMLButtonElement>('start-import');
const existingDevicesBody = element<HTMLTableSectionElement>('existing-devices-body');
const noExistingDevices = element<HTMLElement>('no-existing-devices');
const deviceCount = element<HTMLElement>('device-count');
const selectAllDevices = element<HTMLInputElement>('select-all-devices');
const newTagSelect = element<HTMLSelectElement>('new-group-tag');
const tagChangeButton = element<HTMLButtonElement>('start-tag-change');
const alertBox = element<HTMLElement>('alert');
const resultsPanel = element<HTMLElement>('results-panel');
const resultsTitle = element<HTMLElement>('results-title');
const resultsBody = element<HTMLTableSectionElement>('results-body');
const progressLabel = element<HTMLElement>('progress-label');
const progressBar = element<HTMLElement>('progress-bar');
const historyPanel = element<HTMLElement>('history-panel');
const historyBody = element<HTMLTableSectionElement>('history-body');
const historyScope = element<HTMLElement>('history-scope');
const historyTraceDialog = element<HTMLDialogElement>('history-trace-dialog');
const closeTraceDialog = element<HTMLButtonElement>('close-trace-dialog');
const traceSummary = element<HTMLElement>('trace-summary');
const traceSteps = element<HTMLOListElement>('trace-steps');

let config: RuntimeConfig;
let msal: PublicClientApplication;
let account: AccountInfo | null = null;
let accessTokenResult: AuthenticationResult | null = null;
let tokenAcquisition: Promise<AuthenticationResult> | null = null;
let devices: AutopilotDevice[] = [];
let existingDevices: ExistingAutopilotDevice[] = [];
let results: ImportResult[] = [];
let pollTimer: number | undefined;
let processing = false;

function activateWorkspaceTab(tab: 'import' | 'retag'): void {
  const showImport = tab === 'import';
  importTab.setAttribute('aria-selected', String(showImport));
  importTab.tabIndex = showImport ? 0 : -1;
  retagTab.setAttribute('aria-selected', String(!showImport));
  retagTab.tabIndex = showImport ? -1 : 0;
  importTabPanel.classList.toggle('hidden', !showImport);
  retagTabPanel.classList.toggle('hidden', showImport);
}

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
  importButton.disabled = processing || devices.length === 0 ||
    !tagSelect.value || !account;
}

function selectedExistingDevices(): ExistingAutopilotDevice[] {
  const selectedIds = new Set(
    Array.from(existingDevicesBody.querySelectorAll<HTMLInputElement>(
      'input[data-device-id]:checked',
    )).map((checkbox) => checkbox.dataset.deviceId),
  );
  return existingDevices.filter((device) => selectedIds.has(device.id));
}

function updateTagChangeButton(): void {
  const targetTag = newTagSelect.value;
  tagChangeButton.disabled = processing || !account || !targetTag ||
    !selectedExistingDevices().some((device) => device.groupTag !== targetTag);
}

function updateResults(): void {
  resultsBody.replaceChildren(...results.map((result) => {
    const row = document.createElement('tr');
    const statusClass = result.status === 'error'
      ? 'status-error'
      : result.status === 'complete'
        ? 'status-complete'
        : 'status-pending';
    for (const value of [result.serialNumber, result.operationId ?? '—']) {
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

function formatHistoryDate(value?: string): string {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '—';
  return new Intl.DateTimeFormat(language === 'de' ? 'de-DE' : 'en-US', {
    dateStyle: 'medium',
    timeStyle: 'medium',
  }).format(date);
}

function getHistoryStatus(record: ImportHistoryRecord): 'pending' | 'complete' | 'error' {
  const normalized = record.status?.toLowerCase();
  if (record.deviceErrorName || normalized === 'error' || normalized === 'failed') {
    return 'error';
  }
  if (record.processingCompletedAtUtc) return 'complete';
  return 'pending';
}

function openHistoryTrace(record: ImportHistoryRecord): void {
  const status = getHistoryStatus(record);
  const summaryValues: Array<[TranslationKey, string]> = [
    ['serialNumber', record.serialNumber ?? '—'],
    ['operationId', record.importId ?? '—'],
    ['traceCurrentStatus', t(
      status === 'complete'
        ? 'statusComplete'
        : status === 'error' ? 'statusError' : 'statusPending',
    )],
    ['groupTagLabel', record.groupTag ?? '—'],
  ];
  if (record.previousGroupTag) {
    summaryValues.push(['previousGroupTagLabel', record.previousGroupTag]);
  }
  traceSummary.replaceChildren(...summaryValues.map(([label, value]) => {
    const item = document.createElement('div');
    const term = document.createElement('strong');
    term.textContent = t(label);
    const detail = document.createElement('span');
    detail.textContent = value;
    item.append(term, detail);
    return item;
  }));

  const timeline: Array<[TranslationKey, string | undefined]> = [
    ['traceRequested', record.requestReceivedAtUtc],
    ['traceCreatedInIntune', record.graphImportCreatedAtUtc],
    ['traceQueued', record.queuedAtUtc],
    ['traceStarted', record.processingStartedAtUtc],
    ['traceDeviceResolved', record.entraDeviceResolvedAtUtc],
    ['traceAutopilotTagUpdated', record.autopilotGroupTagUpdatedAtUtc],
    ['traceAttributeUpdated', record.extensionAttributeUpdatedAtUtc],
    ['traceAuUpdated', record.administrativeUnitAssignedAtUtc],
    ['traceCompleted', record.processingCompletedAtUtc],
  ];
  traceSteps.replaceChildren(...timeline
    .filter(([, timestamp]) => Boolean(timestamp))
    .map(([label, timestamp]) => {
      const item = document.createElement('li');
      const marker = document.createElement('span');
      marker.className = 'trace-marker';
      marker.setAttribute('aria-hidden', 'true');
      const content = document.createElement('div');
      const title = document.createElement('strong');
      title.textContent = t(label);
      const time = document.createElement('time');
      time.dateTime = timestamp ?? '';
      time.textContent = formatHistoryDate(timestamp);
      content.append(title, time);
      item.append(marker, content);
      return item;
    }));
  if (status === 'error') {
    const item = document.createElement('li');
    item.className = 'trace-error';
    const marker = document.createElement('span');
    marker.className = 'trace-marker';
    marker.setAttribute('aria-hidden', 'true');
    const content = document.createElement('div');
    const title = document.createElement('strong');
    title.textContent = t('traceError');
    const detail = document.createElement('span');
    detail.textContent = record.deviceErrorName ?? t('statusError');
    content.append(title, detail);
    item.append(marker, content);
    traceSteps.append(item);
  }
  historyTraceDialog.showModal();
}

function renderHistory(records: ImportHistoryRecord[]): void {
  historyPanel.classList.remove('hidden');
  historyBody.replaceChildren(...records.map((record) => {
    const row = document.createElement('tr');
    row.className = 'history-row';
    row.tabIndex = 0;
    row.setAttribute(
      'aria-label',
      `${t('traceOpen')}: ${record.serialNumber ?? t('device')}`,
    );
    row.addEventListener('click', () => openHistoryTrace(record));
    row.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter' && event.key !== ' ') return;
      event.preventDefault();
      openHistoryTrace(record);
    });
    const updatedCell = document.createElement('td');
    updatedCell.textContent = formatHistoryDate(record.lastUpdatedAtUtc);
    row.append(updatedCell);

    const serialCell = document.createElement('td');
    serialCell.textContent = record.serialNumber ?? '—';
    row.append(serialCell);

    const statusCell = document.createElement('td');
    const statusBadge = document.createElement('span');
    const normalized = getHistoryStatus(record);
    const statusClass = normalized === 'error'
      ? 'status-error'
      : normalized === 'complete'
        ? 'status-complete'
        : 'status-pending';
    statusBadge.className = `status ${statusClass}`;
    statusBadge.textContent = normalized === 'error'
      ? t('statusError')
      : normalized === 'complete'
        ? t('statusComplete')
        : t('statusPending');
    statusCell.append(statusBadge);
    row.append(statusCell);

    const requesterCell = document.createElement('td');
    requesterCell.textContent = record.requestedByDisplayName ?? record.requestedBy ?? '—';
    row.append(requesterCell);

    return row;
  }));
}

async function acquireApiToken(): Promise<AuthenticationResult> {
  const selectedAccount = account;
  if (!selectedAccount) throw new Error(t('signInRequired'));
  if (accessTokenResult?.accessToken &&
      (!accessTokenResult.expiresOn ||
       accessTokenResult.expiresOn.getTime() > Date.now() + 60_000)) {
    return accessTokenResult;
  }
  if (!tokenAcquisition) {
    tokenAcquisition = (async () => {
      try {
        return await msal.acquireTokenSilent({
          account: selectedAccount,
          scopes: [config.scope],
          redirectUri: config.silentRedirectUri,
        });
      } catch (error) {
        if (error instanceof BrowserAuthError &&
            error.errorCode === 'monitor_window_timeout') {
          await msal.acquireTokenRedirect({
            account: selectedAccount,
            scopes: [config.scope],
            redirectUri: config.redirectUri,
          });
          return await new Promise<AuthenticationResult>(() => {});
        }
        if (!(error instanceof InteractionRequiredAuthError)) throw error;
        return await msal.acquireTokenPopup({
          account: selectedAccount,
          scopes: [config.scope],
        });
      }
    })();
  }
  try {
    accessTokenResult = await tokenAcquisition;
    return accessTokenResult;
  } finally {
    tokenAcquisition = null;
  }
}

async function apiRequest<T>(url: string, init?: RequestInit): Promise<T> {
  const token = await acquireApiToken();
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
  for (const select of [tagSelect, newTagSelect]) {
    select.replaceChildren();
    const placeholder = document.createElement('option');
    placeholder.value = '';
    placeholder.textContent = response.tags.length > 0 ? t('selectTag') : t('noTags');
    select.append(placeholder);
    for (const tag of response.tags) {
      const option = document.createElement('option');
      option.value = tag;
      option.textContent = tag;
      select.append(option);
    }
    select.disabled = response.tags.length === 0;
  }
  updateImportButton();
  updateTagChangeButton();
  if (response.tags.length === 0) showAlert(t('noTagsForAccount'));
}

function renderExistingDevices(): void {
  existingDevicesBody.replaceChildren(...existingDevices.map((device) => {
    const row = document.createElement('tr');
    const selectionCell = document.createElement('td');
    selectionCell.className = 'selection-cell';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.dataset.deviceId = device.id;
    checkbox.setAttribute('aria-label', `${t('serialNumber')} ${device.serialNumber}`);
    checkbox.addEventListener('change', () => {
      const checkboxes = Array.from(existingDevicesBody.querySelectorAll<HTMLInputElement>(
        'input[data-device-id]',
      ));
      selectAllDevices.checked = checkboxes.length > 0 &&
        checkboxes.every((item) => item.checked);
      selectAllDevices.indeterminate = checkboxes.some((item) => item.checked) &&
        !selectAllDevices.checked;
      updateTagChangeButton();
    });
    selectionCell.append(checkbox);
    row.append(selectionCell);
    for (const value of [
      device.serialNumber,
      device.groupTag,
      device.groups.join(', ') || '—',
      device.administrativeUnits.join(', ') || '—',
    ]) {
      const cell = document.createElement('td');
      cell.textContent = value;
      row.append(cell);
    }
    return row;
  }));
  selectAllDevices.checked = false;
  selectAllDevices.indeterminate = false;
  selectAllDevices.disabled = existingDevices.length === 0;
  noExistingDevices.classList.toggle('hidden', existingDevices.length > 0);
  deviceCount.textContent = `${existingDevices.length} ${
    existingDevices.length === 1 ? t('device') : t('devices')}`;
  updateTagChangeButton();
}

async function loadExistingDevices(): Promise<void> {
  if (!config.deviceTagAssignmentsUrl) return;
  const response = await apiRequest<{ devices?: ExistingAutopilotDevice[] }>(
    config.deviceTagAssignmentsUrl,
  );
  existingDevices = response.devices ?? [];
  renderExistingDevices();
}

async function loadImportHistory(): Promise<void> {
  if (!config?.importHistoryUrl) return;

  const selfUrl = `${config.importHistoryUrl}?top=25`;
  const allUrl = `${config.importHistoryUrl}?top=25&showAll=true`;

  try {
    const allHistory = await apiRequest<{ imports?: ImportHistoryRecord[]; count?: number }>(allUrl);
    historyScope.textContent = t('historyScopeAll');
    renderHistory(allHistory.imports ?? []);
  } catch (error) {
    const message = error instanceof Error ? error.message : '';
    const isForbidden = /403|forbidden|not authorized|historyAccessForbidden/i.test(message);
    if (isForbidden) {
      const selfHistory = await apiRequest<{ imports?: ImportHistoryRecord[]; count?: number }>(selfUrl);
      historyScope.textContent = t('historyScopeSelf');
      renderHistory(selfHistory.imports ?? []);
      return;
    }
    historyScope.textContent = t('historyScopeSelf');
    renderHistory([]);
    showAlert(message || t('statusFailed'));
  }
}

async function setAuthenticatedView(selectedAccount: AccountInfo): Promise<void> {
  account = selectedAccount;
  msal.setActiveAccount(account);
  accountName.textContent = account.name ?? account.username;
  accountUpn.textContent = account.username;
  accountUpn.title = account.username;
  logoutButton.classList.remove('hidden');
  signinView.classList.add('hidden');
  workspace.classList.remove('hidden');
  try {
    await Promise.all([loadTags(), loadImportHistory(), loadExistingDevices()]);
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
  results[index] = {
    serialNumber: device.serialNumber,
    operationType: 'import',
    status: 'sending',
  };
  updateResults();
  try {
    const response = await apiRequest<{ importId: string; status: string }>(config.importUrl, {
      method: 'POST',
      body: JSON.stringify({ ...device, groupTag }),
    });
    results[index] = {
      serialNumber: device.serialNumber,
      operationId: response.importId,
      operationType: 'import',
      status: 'pending',
      detail: response.status,
    };
  } catch (error) {
    results[index] = {
      serialNumber: device.serialNumber,
      operationType: 'import',
      status: 'error',
      detail: error instanceof Error ? error.message : t('importFailed'),
    };
  }
  updateResults();
}

async function changeExistingDeviceTag(
  device: ExistingAutopilotDevice,
  groupTag: string,
  resultIndex: number,
): Promise<void> {
  results[resultIndex] = {
    serialNumber: device.serialNumber,
    operationType: 'tagChange',
    status: 'sending',
  };
  updateResults();
  try {
    const response = await apiRequest<{
      operationId: string;
      status: string;
    }>(config.deviceTagAssignmentsUrl, {
      method: 'POST',
      body: JSON.stringify({ deviceId: device.id, groupTag }),
    });
    results[resultIndex] = {
      serialNumber: device.serialNumber,
      operationId: response.operationId,
      operationType: 'tagChange',
      status: 'pending',
      detail: response.status,
    };
  } catch (error) {
    results[resultIndex] = {
      serialNumber: device.serialNumber,
      operationType: 'tagChange',
      status: 'error',
      detail: error instanceof Error ? error.message : t('tagChangeFailed'),
    };
  }
  updateResults();
}

async function pollResults(): Promise<void> {
  const pending = results.filter((item) => item.operationId && item.status === 'pending');
  await Promise.all(pending.map(async (item) => {
    try {
      const statusUrl = item.operationType === 'import'
        ? `${config.importUrl}?importId=${encodeURIComponent(item.operationId ?? '')}`
        : `${config.deviceTagAssignmentsUrl}?operationId=${encodeURIComponent(item.operationId ?? '')}`;
      const status = await apiRequest<{
        workflowStatus: string;
        status: string;
        deviceErrorName?: string;
      }>(statusUrl);
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
    processing = false;
    const refreshes: Promise<void>[] = [];
    if (results.some((item) => item.operationType === 'import')) {
      refreshes.push(loadImportHistory());
    }
    if (results.some((item) => item.operationType === 'tagChange')) {
      refreshes.push(loadExistingDevices());
    }
    await Promise.all(refreshes);
    updateImportButton();
    updateTagChangeButton();
  }
}

loginButton.addEventListener('click', () => {
  void msal.loginRedirect({ scopes: [config.scope], redirectUri: config.redirectUri });
});
logoutButton.addEventListener('click', () => {
  void msal.logoutRedirect({ account: account ?? undefined, postLogoutRedirectUri: config.redirectUri });
});
closeTraceDialog.addEventListener('click', () => historyTraceDialog.close());
historyTraceDialog.addEventListener('click', (event) => {
  if (event.target === historyTraceDialog) historyTraceDialog.close();
});
tagSelect.addEventListener('change', updateImportButton);
importTab.addEventListener('click', () => activateWorkspaceTab('import'));
retagTab.addEventListener('click', () => activateWorkspaceTab('retag'));
for (const tab of [importTab, retagTab]) {
  tab.addEventListener('keydown', (event) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const showImport = event.key === 'ArrowLeft' || event.key === 'Home';
    activateWorkspaceTab(showImport ? 'import' : 'retag');
    (showImport ? importTab : retagTab).focus();
  });
}
newTagSelect.addEventListener('change', updateTagChangeButton);
selectAllDevices.addEventListener('change', () => {
  existingDevicesBody.querySelectorAll<HTMLInputElement>(
    'input[data-device-id]',
  ).forEach((checkbox) => {
    checkbox.checked = selectAllDevices.checked;
  });
  selectAllDevices.indeterminate = false;
  updateTagChangeButton();
});
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
  processing = true;
  updateImportButton();
  updateTagChangeButton();
  resultsPanel.classList.remove('hidden');
  results = devices.map((device) => ({
    serialNumber: device.serialNumber,
    operationType: 'import',
    status: 'ready',
  }));
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
tagChangeButton.addEventListener('click', async () => {
  const groupTag = newTagSelect.value;
  const selectedDevices = selectedExistingDevices().filter(
    (device) => device.groupTag !== groupTag,
  );
  if (!groupTag || selectedDevices.length === 0) return;
  clearAlert();
  processing = true;
  updateImportButton();
  updateTagChangeButton();
  resultsPanel.classList.remove('hidden');
  results = selectedDevices.map((device) => ({
    serialNumber: device.serialNumber,
    operationType: 'tagChange',
    status: 'ready',
  }));
  updateResults();

  let nextIndex = 0;
  const worker = async (): Promise<void> => {
    while (nextIndex < selectedDevices.length) {
      const index = nextIndex++;
      const device = selectedDevices[index];
      if (device) await changeExistingDeviceTag(device, groupTag, index);
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(3, selectedDevices.length) }, worker),
  );
  await pollResults();
  if (results.some((item) => item.status === 'pending')) {
    pollTimer = window.setInterval(() => void pollResults(), 15_000);
  }
  updateTagChangeButton();
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
    if (redirectResult?.accessToken) accessTokenResult = redirectResult;
    const selectedAccount = redirectResult?.account ?? msal.getAllAccounts()[0];
    if (selectedAccount) await setAuthenticatedView(selectedAccount);
  } catch (error) {
    signinView.classList.add('hidden');
    workspace.classList.remove('hidden');
    showAlert(error instanceof Error ? error.message : t('initializationFailed'));
  }
}

void initialize();
