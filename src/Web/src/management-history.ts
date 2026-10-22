export interface ManagementEvent {
  operationId: string;
  stage: 'requested' | 'applied' | 'failed';
  atUtc: string;
  actorId: string;
  actorName?: string;
  before?: unknown;
  after?: unknown;
}

export interface ManagementHistory {
  events: ManagementEvent[];
  continuation: string;
}

export function managementEventStatus(stage: ManagementEvent['stage']): 'Information' | 'Error' {
  return stage === 'failed' ? 'Error' : 'Information';
}

export function describeManagementChanges(before: unknown, after: unknown, path = ''): string[] {
  if (JSON.stringify(before) === JSON.stringify(after)) return [];
  if (before && after && typeof before === 'object' && typeof after === 'object' &&
      !Array.isArray(before) && !Array.isArray(after)) {
    const oldValues = Object.fromEntries(Object.entries(before));
    const newValues = Object.fromEntries(Object.entries(after));
    return [...new Set([...Object.keys(oldValues), ...Object.keys(newValues)])].flatMap(key =>
      describeManagementChanges(oldValues[key], newValues[key], path ? `${path}.${key}` : key));
  }
  if (Array.isArray(before) && Array.isArray(after) &&
      [...before, ...after].every(value => value && typeof value === 'object' && 'groupId' in value)) {
    const key = (value: { groupId: string; name?: string }): string => `${value.groupId} / ${value.name ?? ''}`;
    return describeManagementChanges(Object.fromEntries(before.map(value => [key(value), value])),
      Object.fromEntries(after.map(value => [key(value), value])), path);
  }
  return [`${path || 'Policy'}: ${JSON.stringify(before) ?? '—'} → ${JSON.stringify(after) ?? '—'}`];
}

export function mountManagementHistoryButton(
  container: HTMLElement,
  request: (continuation?: string) => Promise<ManagementHistory>,
  language: 'de' | 'en',
  scopeName?: () => string,
): HTMLButtonElement {
  const de = language === 'de';
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'button button-quiet';
  button.textContent = de ? 'Policy-Aenderungen' : 'Policy changes';
  const dialog = document.createElement('dialog');
  dialog.className = 'object-picker-dialog management-history-dialog';
  const heading = document.createElement('h2');
  heading.textContent = button.textContent;
  const note = document.createElement('p');
  note.textContent = de
    ? 'Dauerhafte Aufbewahrung. Information kennzeichnet normale Ereignisse, Error einen Fehler. Nur ein Abschlussereignis belegt die Speicherung; die Phase steht in den Details. Aeltere Aenderungen vor Aktivierung der Protokollierung fehlen.'
    : 'Retained indefinitely. Information identifies normal events, Error identifies failures. Only a completion event proves saving; see the phase in the details. Changes before auditing was enabled are not recorded.';
  const status = document.createElement('p');
  status.setAttribute('role', 'status');
  const list = document.createElement('div');
  const more = document.createElement('button');
  more.type = 'button';
  more.hidden = true;
  more.className = 'button button-quiet';
  more.textContent = de ? 'Weitere laden' : 'Load more';
  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'button button-quiet';
  close.textContent = de ? 'Schliessen' : 'Close';
  let continuation = '';
  let busy = false;
  async function load(reset: boolean): Promise<void> {
    if (busy) return;
    busy = true;
    more.disabled = true;
    if (reset) { list.replaceChildren(); continuation = ''; }
    status.textContent = de ? 'Historie wird geladen ...' : 'Loading history ...';
    try {
      const page = await request(continuation || undefined);
      for (const event of page.events) {
        const entry = document.createElement('details');
        entry.className = 'policy-details';
        const title = document.createElement('summary');
        title.textContent = `${new Date(event.atUtc).toLocaleString()} · ${event.actorName || event.actorId} · ${managementEventStatus(event.stage)}`;
        const identity = document.createElement('p');
        identity.textContent = `${event.actorId} · ${event.operationId} · Phase: ${event.stage}`;
        const changes = document.createElement('pre');
        changes.textContent = event.before != null || event.after != null
          ? describeManagementChanges(event.before, event.after).join('\n')
          : `${de ? 'Vorgang' : 'Operation'}: ${event.operationId}`;
        entry.append(title, identity, changes);
        list.append(entry);
      }
      continuation = page.continuation;
      more.hidden = !continuation;
      status.textContent = list.childElementCount ? '' : continuation
        ? (de ? 'Keine Treffer auf dieser Seite. Weitere Eintraege laden.' : 'No matches on this page. Load more entries.')
        : (de ? 'Keine Aenderungen protokolliert.' : 'No recorded changes.');
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : String(error);
    } finally { busy = false; more.disabled = false; }
  }
  button.addEventListener('click', () => {
    heading.textContent = scopeName ? `${button.textContent} - ${scopeName()}` : button.textContent;
    dialog.showModal();
    void load(true);
  });
  more.addEventListener('click', () => { void load(false); });
  close.addEventListener('click', () => dialog.close());
  dialog.append(heading, note, status, list, more, close);
  container.append(button, dialog);
  return button;
}
