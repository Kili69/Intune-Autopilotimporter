import { mountObjectPicker, type SearchGroups } from './group-picker';
import { InteractionRequiredAuthError } from '@azure/msal-browser';
import { ApiRequestError } from './api';
import { mountManagementHistoryButton, type ManagementHistory } from './management-history';

export interface ManagerAccessResponse {
  canManagePolicyManagers: boolean;
}

export async function getManagerAdministrationAccess(
  checkAccess: () => Promise<ManagerAccessResponse>,
  request: () => Promise<unknown>,
): Promise<'denied' | 'signInRequired' | 'allowed'> {
  const access = await checkAccess();
  if (typeof access.canManagePolicyManagers !== 'boolean') {
    throw new Error('Invalid manager access response.');
  }
  if (!access.canManagePolicyManagers) return 'denied';
  try {
    await request();
    return 'allowed';
  } catch (error) {
    if (error instanceof InteractionRequiredAuthError) return 'signInRequired';
    if (error instanceof ApiRequestError && (error.status === 401 || error.status === 403)) return 'denied';
    throw error;
  }
}

export interface ManagerPolicyResponse {
  policy: {
    installerPrincipalId: string;
    additionalPrincipalIds: string[];
    allowIntuneRoleAdministrators: boolean;
  };
  expectedPolicy: string;
}

export function mountManagerEditor(
  container: HTMLElement,
  request: (init?: RequestInit) => Promise<ManagerPolicyResponse>,
  search: SearchGroups,
  language: 'de' | 'en',
  history?: (continuation?: string) => Promise<ManagementHistory>,
): { reload: () => Promise<void> } {
  const de = language === 'de';
  const heading = document.createElement('h2');
  heading.textContent = de ? 'Policy-Manager verwalten' : 'Manage policy managers';
  const status = document.createElement('p');
  status.setAttribute('role', 'status');
  const content = document.createElement('div');
  const load = document.createElement('button');
  load.type = 'button';
  load.className = 'button button-quiet';
  load.textContent = de ? 'Manager neu laden' : 'Reload managers';
  let busy = false;
  let dirty = false;
  let current: ManagerPolicyResponse | undefined;
  function render(response: ManagerPolicyResponse): void {
    current = response;
    content.replaceChildren();
    dirty = false;
    const installer = document.createElement('p');
    installer.textContent = `${de ? 'Installierender Benutzer (geschuetzt)' : 'Installing user (protected)'}: ${response.policy.installerPrincipalId}`;
    const inherited = document.createElement('p');
    inherited.textContent = response.policy.allowIntuneRoleAdministrators
      ? (de ? 'Intune Role Administrator: Zugriff zusaetzlich aktiviert.' : 'Intune Role Administrator access is also enabled.')
      : (de ? 'Intune Role Administrator: kein zusaetzlicher Zugriff.' : 'Intune Role Administrator access is disabled.');
    const pickerHost = document.createElement('div');
    const save = document.createElement('button');
    save.type = 'button';
    save.className = 'button button-primary hidden';
    save.textContent = de ? 'Manager speichern' : 'Save managers';
    const searchAdditional: SearchGroups = async query => {
      const result = await search(query);
      return {
        ...result,
        groups: result.groups.filter(item => item.id.toLowerCase() !== response.policy.installerPrincipalId.toLowerCase()),
      };
    };
    const picker = mountObjectPicker(pickerHost, response.policy.additionalPrincipalIds, searchAdditional, language,
      de ? 'Zusaetzliche Policy-Manager (Benutzer und Gruppen)' : 'Additional policy managers (users and groups)',
      'policyManagers', () => { dirty = true; save.classList.remove('hidden'); });
    save.addEventListener('click', () => {
      if (busy || !current) return;
      if (!window.confirm(de
        ? 'Policy-Manager speichern? Die Function App kann dabei neu starten.'
        : 'Save policy managers? This can restart the Function App.')) return;
      busy = true;
      load.disabled = true;
      content.inert = true;
      status.textContent = de ? 'Manager werden gespeichert ...' : 'Saving managers ...';
      void request({
        method: 'PUT',
        body: JSON.stringify({ additionalPrincipalIds: picker.values(), expectedPolicy: current.expectedPolicy }),
      }).then(result => {
        render(result);
        status.textContent = de ? 'Policy-Manager gespeichert.' : 'Policy managers saved.';
      }).catch((error: unknown) => {
        status.textContent = error instanceof Error ? error.message : String(error);
      }).finally(() => { busy = false; load.disabled = false; content.inert = false; });
    });
    content.append(installer, inherited, pickerHost, save);
    void search(response.policy.installerPrincipalId).then(result => {
      const match = result.groups.find(item => item.id.toLowerCase() === response.policy.installerPrincipalId.toLowerCase());
      if (!match) throw new Error(de ? 'Installierender Benutzer nicht gefunden.' : 'Installing user not found.');
      installer.textContent = `${de ? 'Installierender Benutzer (geschuetzt)' : 'Installing user (protected)'}: ${match.displayName} (${match.id})`;
    }).catch((error: unknown) => { installer.append(` — ${error instanceof Error ? error.message : String(error)}`); });
  }
  async function reload(): Promise<void> {
    if (busy || (dirty && !window.confirm(de
      ? 'Ungespeicherte Manager-Aenderungen verwerfen?'
      : 'Discard unsaved manager changes?'))) return;
    busy = true;
    load.disabled = true;
    content.inert = true;
    status.textContent = de ? 'Manager werden geladen ...' : 'Loading managers ...';
    try {
      render(await request());
      status.textContent = '';
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : String(error);
    } finally {
      busy = false;
      load.disabled = false;
      content.inert = false;
    }
  }
  load.addEventListener('click', () => { void reload(); });
  container.replaceChildren(heading, load, status, content);
  if (history) {
    const historyHost = document.createElement('span');
    load.after(historyHost);
    mountManagementHistoryButton(historyHost, history, language);
  }
  return { reload };
}
