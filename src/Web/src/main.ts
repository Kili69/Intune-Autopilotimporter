import {
  AccountInfo,
  AuthenticationResult,
  BrowserAuthError,
  InteractionRequiredAuthError,
  PublicClientApplication,
} from '@azure/msal-browser';
import { AutopilotDevice, parseAutopilotCsv } from './csv';
import { ApiRequestError, buildApiRequestOptions, canManageTagPolicies } from './api';
import { getHistoryStatus, getImportError, getImportTimeline, getOperationProgress, ImportTimelineRecord, removeOperationsInHistory } from './import-status';
import { getPolicyTagLabel, mountPolicyEditor } from './policy';
import type { GroupSearchResult } from './group-picker';
import { applyCompletedTagChanges, type CompletedTagChange } from './tag-changes';
import { getManagerAdministrationAccess, mountManagerEditor, type ManagerAccessResponse, type ManagerPolicyResponse } from './managers';
import type { ManagementHistory } from './management-history';
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
  tagPolicyUrl: string;
  policyManagersUrl?: string;
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
  status: 'ready' | 'sending' | 'pending' | 'processing' | 'complete' | 'error';
  detail?: string;
  deviceId?: string;
  previousGroupTag?: string;
  groupTag?: string;
  changedAt?: string;
}

interface ExistingAutopilotDevice {
  id: string;
  serialNumber: string;
  groupTag: string;
  groups: string[];
  administrativeUnits: string[];
}

interface ImportHistoryRecord extends ImportTimelineRecord {
  importId?: string;
  operationType?: string;
  serialNumber?: string;
  groupTag?: string;
  previousGroupTag?: string;
  status?: string;
  requestedBy?: string;
  requestedByDisplayName?: string;
  deviceErrorName?: string;
  deviceErrorCode?: number;
  requestReceivedAtUtc?: string;
  graphImportCreatedAtUtc?: string;
  queuedAtUtc?: string;
  processingStartedAtUtc?: string;
  entraDeviceResolvedAtUtc?: string;
  autopilotGroupTagUpdatedAtUtc?: string;
  extensionAttributeUpdatedAtUtc?: string;
  administrativeUnitAssignedAtUtc?: string;
  processingCompletedAtUtc?: string;
  policyName?: string;
  deviceGroupsUpdatedAtUtc?: string;
  lastUpdatedAtUtc?: string;
}

type Language = 'de' | 'en';

const translations = {
  de: {
    homeLabel: 'Autopilot Import Startseite', brandSubtitle: 'Device Hash Import', logout: 'Abmelden', intro: 'Melden Sie sich mit Ihrem Unternehmenskonto an. Berechtigungen und Group Tags werden serverseitig geprüft.',
    login: 'Mit Microsoft Entra ID anmelden', hashLabel: 'Device Hash erstellen', hashIntro: 'Auf dem Zielgerät während der Windows-Ersteinrichtung:',
    hashStep1: 'Mit Umschalt + F10 die Eingabeaufforderung öffnen', hashStep2: 'powershell.exe starten', hashStep3: 'Install-Script Get-WindowsAutopilotInfo -Force ausführen',
    hashStep4: 'Get-WindowsAutopilotInfo -OutputFile D:\\AutopilotHWID.csv ausführen', hashNote: 'Den Laufwerksbuchstaben bei Bedarf an den USB-Stick anpassen.',
    register: 'Geräte in Microsoft Intune registrieren',
    csvHelp: 'Die Datei verbleibt im Browser und wird vor dem Import validiert.', csvSelect: 'CSV auswählen oder hier ablegen', csvRequirements: 'Device Serial Number und Hardware Hash erforderlich',
    tagHelp: 'Es werden nur Tags angezeigt, die für Ihre Entra-Gruppen freigegeben sind.', authorizedTag: 'Autorisierter Tag', loadingTags: 'Tags werden geladen …', startImport: 'Import starten',
    importStatus: 'Verarbeitungsstatus', devicesZero: '0 Geräte', serialNumber: 'Seriennummer', operationId: 'Vorgangs-ID', status: 'Status', statusChangedAt: 'Geändert um', details: 'Details',
    historyTitle: 'Importverlauf', historyScopeSelf: 'Nur eigene Imports', historyScopeAll: 'Alle sichtbaren Imports', requestedBy: 'Angefordert von',
    footer: 'Intune Autopilot Import · Geschützt durch Microsoft Entra ID', author: 'Autor: Andreas Lucas (Kili)', license: 'Apache License 2.0', statusReady: 'Bereit', statusSending: 'Wird gesendet', statusPending: 'Ausstehend', statusProcessing: 'In Bearbeitung', statusComplete: 'Abgeschlossen', statusError: 'Fehler',
    signInRequired: 'Anmeldung erforderlich.', selectTag: 'Tag auswählen', noTags: 'Keine Tags zugewiesen', noTagsForAccount: 'Für Ihr Konto ist kein Group Tag freigegeben.',
    device: 'Gerät', devices: 'Geräte', checked: 'geprüft', tagsLoadFailed: 'Tags konnten nicht geladen werden.', csvValidationFailed: 'CSV konnte nicht validiert werden.',
    importFailed: 'Import fehlgeschlagen.', completedDetail: 'Intune-Import und Geräteattribut abgeschlossen', statusFailed: 'Statusabfrage fehlgeschlagen.',
    completedOf: 'abgeschlossen', frontendNotConfigured: 'Web-Frontend ist nicht vollständig konfiguriert.', initializationFailed: 'Anwendung konnte nicht initialisiert werden.',
    changeTagsTitle: 'Group Tags vorhandener Geräte ändern', changeTagsIntro: 'Noch nicht installierte Geräte aus Ihren Vorhaben auswählen und gemeinsam einem neuen Tag zuordnen.',
    selectAll: 'Alle auswählen', currentTag: 'Aktueller Tag / OrderID', currentGroups: 'Aktuelle Gruppen', administrativeUnits: 'Administrative Unit',
    noEligibleDevices: 'Keine noch nicht installierten Geräte in Ihren Vorhaben gefunden.', targetTag: 'Neuer autorisierter Tag', startTagChange: 'Tag ändern',
    devicesLoadFailed: 'Geräte konnten nicht geladen werden.', tagChangeFailed: 'Tag konnte nicht geändert werden.',
    importTab: 'Import', retagTab: 'Re-Tagging',
    policyTab: 'TagPolicies',
    policyNameLabel: 'Policy',
    lastUpdated: 'Letzte Aktualisierung', traceTitle: 'Vorgangsverlauf', close: 'Schließen', traceCurrentStatus: 'Aktueller Status',
    traceError: 'Fehler', groupTagLabel: 'Group Tag', previousGroupTagLabel: 'Vorheriger Group Tag', traceOpen: 'Vorgangsverlauf öffnen',
  },
  en: {
    homeLabel: 'Autopilot Import home', brandSubtitle: 'Device Hash Import', logout: 'Sign out', intro: 'Sign in with your organizational account. Permissions and Group Tags are validated on the server.',
    login: 'Sign in with Microsoft Entra ID', hashLabel: 'Create a device hash', hashIntro: 'On the target device during Windows setup:',
    hashStep1: 'Press Shift + F10 to open Command Prompt', hashStep2: 'Start powershell.exe', hashStep3: 'Run Install-Script Get-WindowsAutopilotInfo -Force',
    hashStep4: 'Run Get-WindowsAutopilotInfo -OutputFile D:\\AutopilotHWID.csv', hashNote: 'Change the drive letter to match the USB drive if necessary.',
    register: 'Register devices in Microsoft Intune',
    csvHelp: 'The file remains in the browser and is validated before import.', csvSelect: 'Select a CSV or drop it here', csvRequirements: 'Device Serial Number and Hardware Hash are required',
    tagHelp: 'Only tags authorized for your Entra groups are displayed.', authorizedTag: 'Device and Intune Group Tag', loadingTags: 'Loading tags …', startImport: 'Start import',
    importStatus: 'Processing status', devicesZero: '0 devices', serialNumber: 'Serial number', operationId: 'Operation ID', status: 'Status', statusChangedAt: 'Changed at', details: 'Details',
    historyTitle: 'Import history', historyScopeSelf: 'My imports only', historyScopeAll: 'All visible imports', requestedBy: 'Requested by',
    footer: 'Intune Autopilot Import · Protected by Microsoft Entra ID', author: 'Author: Andreas Lucas (Kili)', license: 'Apache License 2.0', statusReady: 'Ready', statusSending: 'Sending', statusPending: 'Pending', statusProcessing: 'Processing', statusComplete: 'Complete', statusError: 'Error',
    signInRequired: 'Sign-in required.', selectTag: 'Select a tag', noTags: 'No tags assigned', noTagsForAccount: 'No Group Tag is authorized for your account.',
    device: 'device', devices: 'devices', checked: 'validated', tagsLoadFailed: 'Tags could not be loaded.', csvValidationFailed: 'The CSV could not be validated.',
    importFailed: 'Import failed.', completedDetail: 'Intune import and device attribute completed', statusFailed: 'Status request failed.',
    completedOf: 'complete', frontendNotConfigured: 'The web frontend is not fully configured.', initializationFailed: 'The application could not be initialized.',
    changeTagsTitle: 'Change Group Tags for existing devices', changeTagsIntro: 'Select devices that have not been installed from your projects and assign a new tag to them.',
    selectAll: 'Select all', currentTag: 'Current tag / OrderID', currentGroups: 'Current groups', administrativeUnits: 'Administrative unit',
    noEligibleDevices: 'No uninstalled devices were found in your projects.', targetTag: 'New authorized tag', startTagChange: 'Change tag',
    devicesLoadFailed: 'Devices could not be loaded.', tagChangeFailed: 'The tag could not be changed.',
    importTab: 'Import', retagTab: 'Re-tagging',
    policyTab: 'Tag policies',
    policyNameLabel: 'Policy',
    lastUpdated: 'Last updated', traceTitle: 'Operation trace', close: 'Close', traceCurrentStatus: 'Current status',
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
      </div>

      <div id="alert" class="alert hidden" role="alert"></div>

      <div class="workspace-tabs" role="tablist" aria-label="${t('register')}">
        <button id="import-tab" class="workspace-tab" type="button" role="tab" aria-selected="true" aria-controls="import-tab-panel">${t('importTab')}</button>
        <button id="retag-tab" class="workspace-tab" type="button" role="tab" aria-selected="false" aria-controls="retag-tab-panel" tabindex="-1">${t('retagTab')}</button>
        <button id="policy-tab" class="workspace-tab hidden" type="button" role="tab" aria-selected="false" aria-controls="policy-tab-panel" tabindex="-1">${t('policyTab')}</button>
        <button id="managers-tab" class="workspace-tab hidden" type="button" role="tab" aria-selected="false" aria-controls="managers-tab-panel" tabindex="-1">${language === 'de' ? 'Policy-Manager' : 'Policy managers'}</button>
      </div>
      <button id="check-manager-access" class="button button-quiet hidden" type="button">${language === 'de' ? 'Azure-Anmeldung fuer Manager-Verwaltung pruefen' : 'Check Azure sign-in for manager administration'}</button>

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
            <button id="reload-devices" class="button button-quiet" type="button">${language === 'de' ? 'Geraete laden' : 'Load devices'}</button>
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

      <section id="policy-tab-panel" class="tab-panel panel hidden" role="tabpanel" aria-labelledby="policy-tab"></section>
      <section id="managers-tab-panel" class="tab-panel panel hidden" role="tabpanel" aria-labelledby="managers-tab"></section>

      <section id="activity-panel" class="panel results-panel">
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
              <thead><tr><th>${t('serialNumber')}</th><th>${t('operationId')}</th><th>${t('status')}</th><th>${t('statusChangedAt')}</th><th>${t('details')}</th></tr></thead>
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
              <thead><tr><th>${t('lastUpdated')}</th><th>${t('serialNumber')}</th><th>${t('operationId')}</th><th>${t('status')}</th><th>${t('requestedBy')}</th></tr></thead>
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
const reloadDevices = element<HTMLButtonElement>('reload-devices');
const activityPanel = element<HTMLElement>('activity-panel');
const policyTab = element<HTMLButtonElement>('policy-tab');
const policyTabPanel = element<HTMLElement>('policy-tab-panel');
const managersTab = element<HTMLButtonElement>('managers-tab');
const managersTabPanel = element<HTMLElement>('managers-tab-panel');
const checkManagerAccess = element<HTMLButtonElement>('check-manager-access');
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
let resultsBatchSize = 0;
let historyOperationIds = new Set<string>();
let pollTimer: number | undefined;
let processing = false;
let policyEditor: ReturnType<typeof mountPolicyEditor> | undefined;
let managerEditor: ReturnType<typeof mountManagerEditor> | undefined;
const armScope = 'https://management.azure.com/user_impersonation';

function activateWorkspaceTab(tab: 'import' | 'retag' | 'policy' | 'managers'): void {
  if (tab === 'policy' && policyTab.classList.contains('hidden')) return;
  if (tab === 'managers' && managersTab.classList.contains('hidden')) return;
  const enteringPolicy = tab === 'policy' && policyTab.getAttribute('aria-selected') !== 'true';
  const enteringManagers = tab === 'managers' && managersTab.getAttribute('aria-selected') !== 'true';
  const showImport = tab === 'import';
  importTab.setAttribute('aria-selected', String(showImport));
  importTab.tabIndex = showImport ? 0 : -1;
  retagTab.setAttribute('aria-selected', String(tab === 'retag'));
  retagTab.tabIndex = tab === 'retag' ? 0 : -1;
  policyTab.setAttribute('aria-selected', String(tab === 'policy'));
  policyTab.tabIndex = tab === 'policy' ? 0 : -1;
  managersTab.setAttribute('aria-selected', String(tab === 'managers'));
  managersTab.tabIndex = tab === 'managers' ? 0 : -1;
  importTabPanel.classList.toggle('hidden', !showImport);
  retagTabPanel.classList.toggle('hidden', tab !== 'retag');
  policyTabPanel.classList.toggle('hidden', tab !== 'policy');
  managersTabPanel.classList.toggle('hidden', tab !== 'managers');
  activityPanel.classList.toggle('hidden', tab === 'policy' || tab === 'managers');
  historyPanel.classList.toggle('hidden', tab === 'policy' || tab === 'managers');
  if (enteringPolicy) void policyEditor?.reload();
  if (enteringManagers) void managerEditor?.reload();
}

document.querySelectorAll<HTMLButtonElement>('[data-language]').forEach((button) => {
  button.addEventListener('click', () => {
    const selectedLanguage = button.dataset.language;
    if (selectedLanguage !== 'de' && selectedLanguage !== 'en') return;
    localStorage.setItem('autopilot-language', selectedLanguage);
    window.location.reload();
  });
});

function showAlert(message: string, kind: 'error' | 'success' | 'info' = 'error'): void {
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
        : result.status === 'processing' ? 'status-processing' : 'status-pending';
    for (const value of [result.serialNumber, result.operationId ?? '—']) {
      const cell = document.createElement('td');
      cell.textContent = value;
      row.append(cell);
    }
    const statusCell = document.createElement('td');
    const badge = document.createElement('span');
    badge.className = `status ${statusClass}`;
    const statusKeys: Record<ImportResult['status'], TranslationKey> = {
      ready: 'statusReady', sending: 'statusSending', pending: 'statusPending', processing: 'statusProcessing',
      complete: 'statusComplete', error: 'statusError',
    };
    badge.textContent = t(statusKeys[result.status]);
    statusCell.append(badge);
    row.append(statusCell);
    result.changedAt ??= new Date().toISOString();
    const changedCell = document.createElement('td');
    changedCell.className = 'status-time';
    changedCell.textContent = formatStatusTime(result.changedAt);
    changedCell.title = formatHistoryDate(result.changedAt);
    row.append(changedCell);
    const detailCell = document.createElement('td');
    detailCell.textContent = result.detail ?? '—';
    row.append(detailCell);
    return row;
  }));

  resultsPanel.classList.toggle('hidden', results.length === 0);
  // Rows of finished operations move to Import History, so progress counts
  // against the size of the submitted batch, not the remaining rows.
  const total = Math.max(resultsBatchSize, results.length);
  const finished = total - results.filter((item) => item.status !== 'complete' && item.status !== 'error').length;
  resultsTitle.textContent = `${results.length} ${results.length === 1 ? t('device') : t('devices')}`;
  progressLabel.textContent = language === 'de'
    ? `${finished} von ${total} ${t('completedOf')}`
    : `${finished} of ${total} ${t('completedOf')}`;
  progressBar.style.width = total === 0 ? '0%' : `${Math.round((finished / total) * 100)}%`;
}

function pruneResultsInHistory(): void {
  const remaining = removeOperationsInHistory(results, historyOperationIds);
  if (remaining.length === results.length) return;
  results = remaining;
  updateResults();
}

function formatStatusTime(value: string): string {
  return new Intl.DateTimeFormat(language === 'de' ? 'de-DE' : 'en-US', { timeStyle: 'medium' })
    .format(new Date(value));
}

// Records when a live status row last changed. Server step timestamps are
// preferred; they never move the displayed time backwards.
function setResultState(item: ImportResult, status: ImportResult['status'], detail: string | undefined, at?: string): void {
  if (item.status === status && item.detail === detail && item.changedAt) return;
  const now = new Date().toISOString();
  const candidate = at && !Number.isNaN(Date.parse(at)) ? at : now;
  item.changedAt = item.changedAt && Date.parse(candidate) < Date.parse(item.changedAt) ? item.changedAt : candidate;
  item.status = status;
  item.detail = detail;
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
  if (record.policyName) summaryValues.push(['policyNameLabel', record.policyName]);
  traceSummary.replaceChildren(...summaryValues.map(([label, value]) => {
    const item = document.createElement('div');
    const term = document.createElement('strong');
    term.textContent = t(label);
    const detail = document.createElement('span');
    detail.textContent = value;
    item.append(term, detail);
    return item;
  }));

  traceSteps.replaceChildren(...getImportTimeline(record, language)
    .map(({ title: label, detail, timestamp }) => {
      const item = document.createElement('li');
      const marker = document.createElement('span');
      marker.className = 'trace-marker';
      marker.setAttribute('aria-hidden', 'true');
      const content = document.createElement('div');
      const title = document.createElement('strong');
      title.textContent = label;
      const description = document.createElement('span');
      description.textContent = detail;
      const time = document.createElement('time');
      time.dateTime = timestamp ?? '';
      time.textContent = formatHistoryDate(timestamp);
      content.append(title, description, time);
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
    detail.textContent = getImportError(record, language) ?? t('statusError');
    content.append(title, detail);
    item.append(marker, content);
    traceSteps.append(item);
  }
  historyTraceDialog.showModal();
}

function renderHistory(records: ImportHistoryRecord[]): void {
  historyOperationIds = new Set(records.flatMap((record) => (
    record.importId ? [record.importId.toLowerCase()] : []
  )));
  historyPanel.classList.toggle('hidden', policyTab.getAttribute('aria-selected') === 'true' ||
    managersTab.getAttribute('aria-selected') === 'true');
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

    const operationCell = document.createElement('td');
    operationCell.className = 'operation-id';
    operationCell.textContent = record.importId ?? '—';
    row.append(operationCell);

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
  const requestInit = buildApiRequestOptions({
    ...init,
    headers: {
      ...init?.headers,
      Authorization: `Bearer ${token.accessToken}`,
    },
  });
  const response = await fetch(url, requestInit);
  const body = await response.json() as T & ApiError;
  if (!response.ok) {
    const detail = body.message ?? body.error ?? `HTTP ${response.status}`;
    const correlation = body.correlationId ? ` Correlation ID: ${body.correlationId}.` : '';
    throw new ApiRequestError(`${detail}.${correlation}`, response.status);
  }
  return body;
}

async function loadTags(): Promise<void> {
  const response = await apiRequest<{ tags: string[]; policies?: Array<{ name: string; tags: string[] }> }>(config.tagsUrl);
  for (const select of [tagSelect, newTagSelect]) {
    select.replaceChildren();
    const placeholder = document.createElement('option');
    placeholder.value = '';
    placeholder.textContent = response.tags.length > 0 ? t('selectTag') : t('noTags');
    select.append(placeholder);
    for (const tag of response.tags) {
      const option = document.createElement('option');
      option.value = tag;
      option.textContent = getPolicyTagLabel(tag, response.policies);
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
  if (reloadDevices.disabled) return;
  reloadDevices.disabled = true;
  reloadDevices.textContent = language === 'de' ? 'Geraete werden geladen ...' : 'Loading devices ...';
  try {
    if (!config.deviceTagAssignmentsUrl) return;
    const response = await apiRequest<{ devices?: ExistingAutopilotDevice[] }>(
      config.deviceTagAssignmentsUrl,
    );
    existingDevices = applyCompletedTagChanges(response.devices ?? [], completedTagChanges());
    renderExistingDevices();
  } finally {
    reloadDevices.disabled = false;
    reloadDevices.textContent = language === 'de' ? 'Geraete laden' : 'Load devices';
  }
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

async function loadPolicyAccess(): Promise<void> {
  policyTab.classList.add('hidden');
  if (policyTab.getAttribute('aria-selected') === 'true') activateWorkspaceTab('import');
  policyTabPanel.replaceChildren();
  policyEditor = undefined;
  if (!await canManageTagPolicies(() => apiRequest(config.tagPolicyUrl))) return;
  policyEditor = mountPolicyEditor(policyTabPanel, <T>(init?: RequestInit) => apiRequest<T>(config.tagPolicyUrl, init),
    language, async () => { await Promise.all([loadTags(), loadExistingDevices()]); },
    query => {
      const url = new URL(config.tagPolicyUrl, window.location.origin);
      url.searchParams.set('groupSearch', query);
      return apiRequest<GroupSearchResult>(url.toString());
    },
    query => {
      const url = new URL(config.tagPolicyUrl, window.location.origin);
      url.searchParams.set('auSearch', query);
      return apiRequest<GroupSearchResult>(url.toString());
    }, (ruleId, continuation) => {
      const url = new URL(config.tagPolicyUrl, window.location.origin);
      url.searchParams.set('history', 'true');
      url.searchParams.set('ruleId', ruleId);
      if (continuation) url.searchParams.set('continuation', continuation);
      return apiRequest<ManagementHistory>(url.toString());
    });
  policyTab.classList.remove('hidden');
}

async function managerRequest<T>(init?: RequestInit, search?: string, continuation?: string): Promise<T> {
  if (!account || !config.policyManagersUrl) throw new Error(t('signInRequired'));
  const token = await msal.acquireTokenSilent({
    account, scopes: [armScope], redirectUri: config.silentRedirectUri,
  });
  const url = new URL(config.policyManagersUrl, window.location.origin);
  if (search !== undefined) url.searchParams.set('search', search);
  if (continuation !== undefined) {
    url.searchParams.set('history', 'true');
    if (continuation) url.searchParams.set('continuation', continuation);
  }
  return apiRequest<T>(url.toString(), {
    ...init, headers: { 'x-autopilot-arm-token': token.accessToken },
  });
}

async function loadManagerAccess(): Promise<void> {
  managersTab.classList.add('hidden');
  checkManagerAccess.classList.add('hidden');
  if (managersTab.getAttribute('aria-selected') === 'true') activateWorkspaceTab('import');
  managerEditor = undefined;
  managersTabPanel.replaceChildren();
  if (!config.policyManagersUrl) return;
  try {
    const url = new URL(config.policyManagersUrl, window.location.origin);
    url.searchParams.set('access', 'true');
    const access = await getManagerAdministrationAccess(
      () => apiRequest<ManagerAccessResponse>(url.toString()),
      () => managerRequest<ManagerPolicyResponse>());
    if (access === 'denied') return;
    if (access === 'signInRequired') {
      checkManagerAccess.classList.remove('hidden');
      return;
    }
    managerEditor = mountManagerEditor(managersTabPanel,
      init => managerRequest<ManagerPolicyResponse>(init),
      query => managerRequest<GroupSearchResult>(undefined, query), language,
      continuation => managerRequest<ManagementHistory>(undefined, undefined, continuation ?? ''));
    managersTab.classList.remove('hidden');
  } catch (error) {
    showAlert(error instanceof Error ? error.message : String(error));
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
    await Promise.all([loadTags(), loadImportHistory(), loadExistingDevices(), loadPolicyAccess(), loadManagerAccess()]);
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
      detail: getOperationProgress({ operationType: 'import', status: response.status }, language).detail,
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
      detail: getOperationProgress({ operationType: 'tagChange', status: response.status }, language).detail,
      deviceId: device.id,
      previousGroupTag: device.groupTag,
      groupTag,
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

function isActiveResult(item: ImportResult): boolean {
  return item.status === 'pending' || item.status === 'processing';
}

function completedTagChanges(): CompletedTagChange[] {
  return results.flatMap((item) => (
    item.operationType === 'tagChange' && item.status === 'complete' &&
    item.deviceId && item.previousGroupTag !== undefined && item.groupTag
      ? [{ deviceId: item.deviceId, previousGroupTag: item.previousGroupTag, groupTag: item.groupTag }]
      : []
  ));
}

async function pollResults(): Promise<void> {
  const pending = results.filter((item) => item.operationId && isActiveResult(item));
  let newlyFinished = false;
  await Promise.all(pending.map(async (item) => {
    try {
      const statusUrl = item.operationType === 'import'
        ? `${config.importUrl}?importId=${encodeURIComponent(item.operationId ?? '')}`
        : `${config.deviceTagAssignmentsUrl}?operationId=${encodeURIComponent(item.operationId ?? '')}`;
      const status = await apiRequest<ImportTimelineRecord & {
        workflowStatus: string;
        status: string;
        processingStage?: string;
        deviceErrorName?: string;
        deviceErrorCode?: number;
        processingError?: string | null;
      }>(statusUrl);
      if (status.workflowStatus === 'complete') {
        setResultState(item, 'complete', t('completedDetail'), status.processingCompletedAtUtc);
        newlyFinished = true;
      } else if (status.workflowStatus === 'error') {
        setResultState(item, 'error', getImportError(status, language) ?? status.processingError ?? status.status,
          status.processingFailedAtUtc ?? status.processingErrorAtUtc ?? undefined);
        newlyFinished = true;
      } else {
        const progress = getOperationProgress({ ...status, operationType: item.operationType }, language);
        setResultState(item, progress.state, progress.detail, progress.changedAt);
      }
    } catch (error) {
      setResultState(item, item.status, error instanceof Error ? error.message : t('statusFailed'));
    }
  }));
  updateResults();
  if (completedTagChanges().length > 0) {
    const updatedDevices = applyCompletedTagChanges(existingDevices, completedTagChanges());
    if (updatedDevices.some((device, index) => device !== existingDevices[index])) {
      existingDevices = updatedDevices;
      renderExistingDevices();
    }
  }
  if (results.every((item) => item.status === 'complete' || item.status === 'error')) {
    if (pollTimer !== undefined) window.clearInterval(pollTimer);
    pollTimer = undefined;
    processing = false;
    const refreshes: Promise<void>[] = [loadImportHistory()];
    if (results.some((item) => item.operationType === 'tagChange')) {
      refreshes.push(loadExistingDevices());
    }
    await Promise.all(refreshes);
    pruneResultsInHistory();
    updateImportButton();
    updateTagChangeButton();
  } else if (newlyFinished) {
    await loadImportHistory().catch(() => undefined);
    pruneResultsInHistory();
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
reloadDevices.addEventListener('click', () => {
  clearAlert();
  void loadExistingDevices().catch((error: unknown) => {
    showAlert(error instanceof Error ? error.message : String(error));
  });
});
policyTab.addEventListener('click', () => activateWorkspaceTab('policy'));
managersTab.addEventListener('click', () => activateWorkspaceTab('managers'));
checkManagerAccess.addEventListener('click', () => {
  if (!account) return;
  void msal.acquireTokenRedirect({
    account, scopes: [armScope], redirectUri: config.redirectUri,
  }).catch((error: unknown) => { showAlert(error instanceof Error ? error.message : String(error)); });
});
const workspaceTabs = [importTab, retagTab, policyTab, managersTab];
for (const tab of workspaceTabs) {
  tab.addEventListener('keydown', (event) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const visibleTabs = workspaceTabs.filter(button => !button.classList.contains('hidden'));
    const index = event.key === 'Home' ? 0 : event.key === 'End' ? visibleTabs.length - 1
      : (visibleTabs.indexOf(tab) + (event.key === 'ArrowLeft' ? visibleTabs.length - 1 : 1)) % visibleTabs.length;
    const button = visibleTabs[index];
    const target = button === importTab ? 'import' : button === retagTab ? 'retag' : button === policyTab ? 'policy' : 'managers';
    if (button) {
      activateWorkspaceTab(target);
      button.focus();
    }
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
  resultsBatchSize = devices.length;
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
  if (results.some(isActiveResult)) {
    pollTimer = window.setInterval(() => void pollResults(), 15_000);
  }
  updateImportButton();
});
tagChangeButton.addEventListener('click', async () => {
  const groupTag = newTagSelect.value;
  const selection = selectedExistingDevices();
  const selectedDevices = selection.filter((device) => device.groupTag !== groupTag);
  const unchangedDevices = selection.filter((device) => device.groupTag === groupTag);
  if (!groupTag || selectedDevices.length === 0) return;
  clearAlert();
  if (unchangedDevices.length > 0) {
    const serials = unchangedDevices.map((device) => device.serialNumber).join(', ');
    showAlert(language === 'de'
      ? `${unchangedDevices.length} ausgewählte(s) Gerät(e) hat/haben bereits das Tag ${groupTag} und wurde(n) übersprungen: ${serials}`
      : `${unchangedDevices.length} selected device(s) already use the tag ${groupTag} and were skipped: ${serials}`, 'info');
  }
  processing = true;
  updateImportButton();
  updateTagChangeButton();
  resultsPanel.classList.remove('hidden');
  resultsBatchSize = selectedDevices.length;
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
  if (results.some(isActiveResult)) {
    // Tag changes finish within seconds once the queue worker starts; poll
    // more often so intermediate steps become visible.
    pollTimer = window.setInterval(() => void pollResults(), 5_000);
    void loadImportHistory().catch(() => undefined);
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
    if (redirectResult?.accessToken && redirectResult.scopes.some(
      scope => scope.toLowerCase() === config.scope.toLowerCase(),
    )) accessTokenResult = redirectResult;
    const selectedAccount = redirectResult?.account ?? msal.getAllAccounts()[0];
    if (selectedAccount) await setAuthenticatedView(selectedAccount);
  } catch (error) {
    signinView.classList.add('hidden');
    workspace.classList.remove('hidden');
    showAlert(error instanceof Error ? error.message : t('initializationFailed'));
  }
}

void initialize();
