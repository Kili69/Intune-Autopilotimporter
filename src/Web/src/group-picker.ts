export interface EntraGroup {
  id: string;
  displayName: string;
}

export interface GroupSearchResult {
  groups: EntraGroup[];
  hasMore: boolean;
}

export type SearchGroups = (query: string) => Promise<GroupSearchResult>;

export function mountObjectPicker(
  container: HTMLElement,
  initial: string[],
  searchObjects: SearchGroups,
  language: 'de' | 'en',
  label: string,
  kind: 'userGroup' | 'deviceGroups' | 'administrativeUnit' | 'policyManagers',
  onChanged: () => void,
): { values: () => string[] } {
  const de = language === 'de';
  const au = kind === 'administrativeUnit';
  const managers = kind === 'policyManagers';
  const multiple = kind === 'deviceGroups' || managers;
  let values = [...initial];
  const names = new Map<string, string>();
  const section = document.createElement('section');
  section.className = 'object-picker';
  const listLabel = document.createElement('label');
  listLabel.className = 'field-label';
  if (kind === 'deviceGroups' || au) {
    const heading = document.createElement('span');
    heading.className = 'policy-section-title';
    heading.setAttribute('role', 'heading');
    heading.setAttribute('aria-level', '3');
    heading.textContent = label;
    listLabel.append(heading);
  } else {
    listLabel.append(document.createTextNode(label));
  }
  const selected = document.createElement('select');
  selected.size = multiple ? 4 : 2;
  listLabel.append(selected);
  const status = document.createElement('p');
  status.setAttribute('role', 'status');
  function button(text: string): HTMLButtonElement {
    const element = document.createElement('button');
    element.type = 'button';
    element.className = 'button button-quiet';
    element.textContent = text;
    return element;
  }
  const add = button(managers ? (de ? 'Manager hinzufuegen' : 'Add manager') : au ? (de ? 'AU hinzufuegen' : 'Add AU') : (de ? 'Gruppe hinzufuegen' : 'Add group'));
  const remove = button(managers ? (de ? 'Manager entfernen' : 'Remove manager') : au ? (de ? 'AU entfernen' : 'Remove AU') : (de ? 'Gruppe entfernen' : 'Remove group'));
  remove.disabled = true;
  function render(): void {
    selected.replaceChildren();
    for (const value of values) {
      const option = document.createElement('option');
      option.value = value;
      option.textContent = au ? value : names.get(value.toLowerCase()) ?? (managers
        ? (de ? 'Objektname wird geladen ...' : 'Loading object name ...')
        : (de ? 'Gruppenname wird geladen ...' : 'Loading group name ...'));
      option.title = value;
      selected.append(option);
    }
    selected.selectedIndex = -1;
    remove.disabled = true;
    add.disabled = au && values.length > 0;
  }
  selected.addEventListener('change', () => { remove.disabled = selected.selectedIndex < 0; });
  remove.addEventListener('click', () => {
    if (selected.selectedIndex < 0) return;
    values = values.filter(value => value !== selected.value);
    render();
    onChanged();
  });
  const dialog = document.createElement('dialog');
  dialog.className = 'object-picker-dialog';
  const title = document.createElement('h2');
  title.textContent = label;
  const searchLabel = document.createElement('label');
  searchLabel.className = 'field-label';
  searchLabel.append(document.createTextNode(de ? 'Suchen (Namensanfang oder Objekt-ID)' : 'Search (name prefix or object ID)'));
  const search = document.createElement('input');
  search.type = 'search';
  search.maxLength = 128;
  searchLabel.append(search);
  const searchButton = button(de ? 'Suchen' : 'Search');
  const feedback = document.createElement('p');
  feedback.setAttribute('role', 'status');
  const results = document.createElement('ul');
  results.className = 'group-picker-results';
  const close = button(de ? 'Abbrechen' : 'Cancel');
  close.addEventListener('click', () => dialog.close());
  let revision = 0;
  dialog.addEventListener('close', () => { revision++; });
  search.addEventListener('input', () => {
    revision++;
    results.replaceChildren();
    feedback.textContent = '';
  });
  async function runSearch(): Promise<void> {
    const query = search.value.trim();
    if (searchButton.disabled) return;
    results.replaceChildren();
    if (query.length < 2 || query.length > 128) {
      feedback.textContent = de ? 'Bitte 2 bis 128 Zeichen eingeben.' : 'Enter 2 to 128 characters.';
      return;
    }
    const current = ++revision;
    searchButton.disabled = true;
    feedback.textContent = de ? 'Suche laeuft ...' : 'Searching ...';
    try {
      const response = await searchObjects(query);
      if (revision !== current || !dialog.open) return;
      feedback.textContent = response.hasMore
        ? (de ? 'Erste 25 Treffer. Suche eingrenzen.' : 'First 25 matches. Refine your search.')
        : response.groups.length ? '' : (de ? 'Keine Treffer.' : 'No matches.');
      for (const object of response.groups) {
        const item = document.createElement('li');
        const select = button(`${object.displayName} (${object.id})`);
        select.classList.add('group-picker-result');
        select.disabled = values.some(value => au ? value === object.displayName : value.toLowerCase() === object.id.toLowerCase());
        select.addEventListener('click', () => {
          names.set(object.id.toLowerCase(), object.displayName);
          const value = au ? object.displayName : object.id.toLowerCase();
          values = multiple ? [...values, value] : [value];
          render();
          onChanged();
          dialog.close();
        });
        item.append(select);
        results.append(item);
      }
    } catch (error) {
      if (revision === current && dialog.open) feedback.textContent = error instanceof Error ? error.message : String(error);
    } finally {
      searchButton.disabled = false;
    }
  }
  searchButton.addEventListener('click', () => { void runSearch(); });
  search.addEventListener('keydown', event => {
    if (event.key === 'Enter') { event.preventDefault(); void runSearch(); }
  });
  add.addEventListener('click', () => {
    search.value = '';
    results.replaceChildren();
    feedback.textContent = '';
    dialog.showModal();
    search.focus();
  });
  dialog.append(title, searchLabel, searchButton, feedback, results, close);
  section.append(listLabel, add, remove, status, dialog);
  container.append(section);
  render();
  if (!au) {
    for (const value of values) {
      void searchObjects(value).then(response => {
        const match = response.groups.find(group => group.id.toLowerCase() === value.toLowerCase());
        if (!match) throw new Error(managers
          ? (de ? `Objekt nicht gefunden: ${value}` : `Object not found: ${value}`)
          : (de ? `Gruppe nicht gefunden: ${value}` : `Group not found: ${value}`));
        names.set(value.toLowerCase(), match.displayName);
        const option = Array.from(selected.options).find(option => option.value === value);
        if (option) option.textContent = match.displayName;
      }).catch((error: unknown) => {
        const option = Array.from(selected.options).find(option => option.value === value);
        if (option) option.textContent = managers ? value : (de ? 'Gruppenname nicht aufloesbar' : 'Group name unavailable');
        status.textContent = error instanceof Error ? error.message : String(error);
      });
    }
  }
  return { values: () => [...values] };
}
