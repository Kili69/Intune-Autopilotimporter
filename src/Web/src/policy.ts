import { mountObjectPicker, SearchGroups } from './group-picker';
import { mountManagementHistoryButton, type ManagementHistory } from './management-history';

export interface TagPolicyRule {
  ruleId?: string;
  name?: string;
  description?: string;
  groupId: string;
  tags: string[];
  groupTag?: string;
  extensionAttributes?: Record<string, string>;
  deviceGroupIds?: string[];
  administrativeUnitName?: string;
}

export interface PolicyFields {
  name: string;
  description?: string;
  groupId: string;
  groupTag: string;
  attributes: string | Record<string, string>;
  groups: string;
  administrativeUnitName: string;
}

const guid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function getPolicyTagLabel(tag: string, policies: Array<Pick<TagPolicyRule, 'name' | 'tags'>> = []): string {
  const names = policies.filter(rule => rule.tags.includes(tag))
    .map(rule => rule.name?.trim())
    .filter((name): name is string => !!name && !guid.test(name.replace(/^Policy /i, '')));
  return [...new Set(names)].join(' / ') || tag;
}

export function validatePolicyTags(group: string): string {
  const groupTag = group.trim();
  if (!groupTag) return 'Specify a Group Tag.';
  if (groupTag.length > 128) return 'Project limit: Group Tag must not exceed 128 characters.';
  if (groupTag.includes(',')) return 'Group Tag must not contain a comma (policy format).';
  return '';
}

export function validateExtensionAttributeValue(value: string): string {
  if (value.length > 1024) return 'Extension attribute values must not exceed 1024 characters.';
  if (/[\p{Cc}\p{Zl}\p{Zp}]/u.test(value)) return 'Extension attribute values must be single-line, without control characters.';
  return '';
}

export function parsePolicyFields(fields: PolicyFields, legacy?: TagPolicyRule): TagPolicyRule {
  const name = fields.name.trim();
  const description = fields.description ?? '';
  if (description.length > 2048 || /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(description)) {
    throw new Error('Policy description: max. 2048 characters, no control characters.');
  }
  const groupId = fields.groupId.trim();
  const groupTag = fields.groupTag.trim();
  if (!name || name.length > 128) throw new Error('Policy name: 1..128 characters.');
  if (!guid.test(groupId) || /^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(groupId)) {
    throw new Error('User group ID must be a non-empty GUID.');
  }
  // Legacy multi-tag rules need an explicit single-tag conversion before adding actions.
  if (legacy && !legacy.groupTag &&
      fields.groupTag.trim() === legacy.tags.join(', ') &&
      typeof fields.attributes === 'string' && !fields.attributes.trim() &&
      !fields.groups.trim()) {
    return { ...(legacy?.ruleId ? { ruleId: legacy.ruleId } : {}), name, description, groupId, tags: [...legacy.tags], administrativeUnitName: fields.administrativeUnitName.trim() };
  }
  const tagError = validatePolicyTags(fields.groupTag);
  if (tagError) throw new Error(tagError);
  const extensionAttributes: Record<string, string> = {};
  const attributeEntries: Array<[string, string]> = typeof fields.attributes === 'string'
    ? fields.attributes.split(/\r?\n/).filter(value => value.trim()).map(line => {
    const separator = line.indexOf('=');
    if (separator < 0) throw new Error('Extension attributes require key=value.');
    const key = line.slice(0, separator).trim();
    const value = line.slice(separator + 1);
    return [key, value];
  }) : Object.entries(fields.attributes);
  for (const [key, value] of attributeEntries) {
    if (!/^extensionAttribute([1-9]|1[0-5])$/.test(key) ||
        Object.hasOwn(extensionAttributes, key)) {
      throw new Error('Extension attributes: one unique extensionAttribute1..15=value per line, max. 1024 characters.');
    }
    const valueError = validateExtensionAttributeValue(value);
    if (valueError) throw new Error(valueError);
    extensionAttributes[key] = value;
  }
  const deviceGroupIds = [...new Set(fields.groups.split(/[\s,;]+/).filter(Boolean))];
  if (deviceGroupIds.some(id => !guid.test(id) || /^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(id))) {
    throw new Error('Device target groups must be non-empty GUIDs.');
  }
  const rule: TagPolicyRule = {
    ...(legacy?.ruleId ? { ruleId: legacy.ruleId } : {}),
    name, description, groupId, groupTag, tags: [groupTag], deviceGroupIds,
    administrativeUnitName: fields.administrativeUnitName.trim(),
  };
  rule.extensionAttributes = extensionAttributes;
  return rule;
}

function ruleKey(rule: TagPolicyRule): string {
  if (rule.ruleId) return rule.ruleId.toLowerCase();
  return `${rule.groupId.toLowerCase()}|${(rule.name ?? `Policy ${rule.groupId}`).toLowerCase()}`;
}

function stableJson(value: unknown): string {
  return JSON.stringify(value, (_key, item: unknown) => {
    if (item && typeof item === 'object' && !Array.isArray(item)) {
      return Object.fromEntries(Object.entries(item).sort(([a], [b]) => a.localeCompare(b)));
    }
    return item;
  });
}

export function updateSingleRule(
  latest: TagPolicyRule[], original: TagPolicyRule | undefined, replacement?: TagPolicyRule,
): TagPolicyRule[] {
  const index = original ? latest.findIndex(rule => ruleKey(rule) === ruleKey(original)) : -1;
  if (original && (index < 0 || stableJson(latest[index]) !== stableJson(original))) {
    throw new Error('This rule changed on the server. Reload policies before saving.');
  }
  if (replacement && latest.some((rule, position) => position !== index &&
      (ruleKey(rule) === ruleKey(replacement) ||
       (rule.groupId.toLowerCase() === replacement.groupId.toLowerCase() &&
        (rule.name ?? '').toLowerCase() === (replacement.name ?? '').toLowerCase())))) {
    throw new Error('A rule with this name and user group already exists.');
  }
  const policy = latest.filter((_rule, position) => position !== index);
  if (replacement) policy.splice(index < 0 ? policy.length : index, 0, replacement);
  if (!policy.length) throw new Error('At least one rule is required.');
  return policy;
}

export function mountPolicyEditor(
  container: HTMLElement,
  request: <T>(init?: RequestInit) => Promise<T>,
  language: 'de' | 'en',
  onSaved: () => Promise<void>,
  searchGroups: SearchGroups,
  searchAdministrativeUnits: SearchGroups,
  history?: (ruleId: string, continuation?: string) => Promise<ManagementHistory>,
): { reload: () => Promise<void> } {
  const de = language === 'de';
  const text = {
    title: de ? 'TagPolicies verwalten' : 'Manage tag policies',
    load: de ? 'Policies neu laden' : 'Reload policies',
    add: de ? 'Regel hinzufuegen' : 'Add rule',
    save: de ? 'Regel speichern' : 'Save rule',
    remove: de ? 'Regel entfernen' : 'Remove rule',
    confirm: de ? 'Sind Sie sicher, dass Sie diese Regel entfernen moechten?' : 'Are you sure you want to remove this rule?',
    saved: de ? 'Regel aktualisiert.' : 'Rule updated.',
  };
  const heading = document.createElement('h2');
  heading.textContent = text.title;
  const status = document.createElement('p');
  status.setAttribute('role', 'status');
  const list = document.createElement('div');
  const load = document.createElement('button');
  const add = document.createElement('button');
  for (const [button, label] of [[load, text.load], [add, text.add]] as const) {
    button.type = 'button';
    button.className = 'button button-quiet';
    button.textContent = label;
  }
  add.disabled = true;
  let rows: Array<{ element: HTMLDetailsElement; dirty: () => boolean }> = [];
  let busy = false;
  let loaded = false;
  function addRule(rule?: TagPolicyRule): HTMLDetailsElement {
    let original = rule;
    const draftId = rule?.ruleId ?? crypto.randomUUID();
    const details = document.createElement('details');
    details.className = 'policy-details';
    details.open = !rule;
    const summary = document.createElement('summary');
    summary.textContent = rule?.name ?? (de ? 'Neue Regel' : 'New rule');
    const fieldset = document.createElement('fieldset');
    fieldset.className = 'policy-rule';
    const values: PolicyFields = {
      name: rule?.name ?? (rule ? `Policy ${rule.groupId}` : ''),
      description: rule?.description ?? '',
      groupId: rule?.groupId ?? '',
      groupTag: rule?.groupTag ?? rule?.tags.join(', ') ?? '',
      attributes: rule?.extensionAttributes ?? {},
      groups: rule?.deviceGroupIds?.join('\n') ?? '',
      administrativeUnitName: rule?.administrativeUnitName ?? '',
    };
    const labels: Record<keyof PolicyFields, string> = {
      name: de ? 'Policy-Name' : 'Policy name',
      description: de ? 'Beschreibung' : 'Description',
      groupId: de ? 'Berechtigte Benutzergruppe (Objekt-ID)' : 'Authorized user group (object ID)',
      groupTag: 'Autopilot Group Tag',
      attributes: 'Extension Attributes',
      groups: de ? 'Entra-Geraetezielgruppen' : 'Entra device target groups',
      administrativeUnitName: 'Administrative Unit',
    };
    const inputs = new Map<keyof PolicyFields, HTMLInputElement | HTMLTextAreaElement>();
    const attributeRows: Array<{ select: HTMLSelectElement; value: HTMLInputElement }> = [];
    const objectPickers = new Map<keyof PolicyFields, { values: () => string[] }>();
    const save = document.createElement('button');
    save.type = 'button';
    save.className = 'button';
    save.textContent = text.save;
    const rowStatus = document.createElement('p');
    rowStatus.setAttribute('role', 'status');
    let historyButton: HTMLButtonElement | undefined;
    if (history) {
      const historyHost = document.createElement('span');
      fieldset.append(historyHost);
      historyButton = mountManagementHistoryButton(historyHost, continuation => {
        if (!original?.ruleId) return Promise.reject(new Error(de ? 'Regel zuerst speichern.' : 'Save the rule first.'));
        return history(original.ruleId, continuation);
      }, language, () => original?.name ?? values.name);
      historyButton.disabled = !original?.ruleId;
    }
    function readFields(): PolicyFields {
      const fields = { ...values };
      for (const [key, input] of inputs) fields[key] = input.value;
      fields.attributes = Object.fromEntries(attributeRows.map(row => [row.select.value, row.value.value]));
      fields.groupId = objectPickers.get('groupId')?.values()[0] ?? '';
      fields.groups = objectPickers.get('groups')?.values().join('\n') ?? '';
      fields.administrativeUnitName = objectPickers.get('administrativeUnitName')?.values()[0] ?? '';
      return fields;
    }
    let baseline = '';
    function dirty(): boolean { return !original || stableJson(readFields()) !== baseline; }
    function changed(): void {
      save.hidden = !dirty();
      rowStatus.textContent = '';
    }
    let addAttribute: HTMLButtonElement;
    function refreshAttributeChoices(): void {
      const used = new Set(attributeRows.map(row => row.select.value));
      for (const row of attributeRows) {
        for (const option of row.select.options) option.disabled = used.has(option.value) && option.value !== row.select.value;
      }
      addAttribute.disabled = attributeRows.length >= 15;
    }
    function appendAttribute(key?: string, value = ''): void {
      const used = new Set(attributeRows.map(row => row.select.value));
      const available = Array.from({ length: 15 }, (_, index) => `extensionAttribute${index + 1}`).find(name => !used.has(name));
      if (!key && !available) return;
      const element = document.createElement('div');
      element.className = 'policy-attribute-row';
      const selectLabel = document.createElement('label');
      selectLabel.textContent = de ? 'ExtensionAttribute auswaehlen' : 'Select extension attribute';
      const select = document.createElement('select');
      for (let index = 1; index <= 15; index++) {
        const option = document.createElement('option');
        option.value = option.textContent = `extensionAttribute${index}`;
        select.append(option);
      }
      select.value = key ?? available ?? '';
      selectLabel.append(select);
      const valueLabel = document.createElement('label');
      valueLabel.textContent = de ? 'Attributwert' : 'Attribute value';
      const input = document.createElement('input');
      input.type = 'text';
      input.value = value;
      input.maxLength = 1024;
      const feedback = document.createElement('span');
      feedback.setAttribute('role', 'status');
      function validateValue(candidate: string): void {
        const error = validateExtensionAttributeValue(candidate);
        const message = error && de
          ? (candidate.length > 1024 ? 'Maximal 1024 Zeichen.' : 'Nur einzeilige Werte ohne Steuerzeichen erlaubt.')
          : error;
        input.setCustomValidity(message);
        feedback.textContent = message;
      }
      validateValue(value);
      input.addEventListener('input', () => validateValue(input.value));
      input.addEventListener('paste', event => {
        const pasted = event.clipboardData?.getData('text/plain');
        if (pasted !== undefined && /[\p{Cc}\p{Zl}\p{Zp}]/u.test(pasted)) {
          event.preventDefault();
          validateValue(pasted);
        }
      });
      valueLabel.append(input, feedback);
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'button button-quiet';
      remove.textContent = de ? 'Attribut entfernen' : 'Remove attribute';
      const row = { select, value: input };
      select.addEventListener('change', () => { refreshAttributeChoices(); changed(); });
      remove.addEventListener('click', () => {
        attributeRows.splice(attributeRows.indexOf(row), 1);
        element.remove();
        refreshAttributeChoices();
        changed();
      });
      element.append(selectLabel, valueLabel, remove);
      attributeRows.push(row);
      attributeContainer.append(element);
    }
    const attributeContainer = document.createElement('div');
    for (const key of Object.keys(values) as Array<keyof PolicyFields>) {
      if (key === 'attributes') {
        const title = document.createElement('h3');
        title.className = 'policy-section-title';
        title.textContent = 'Extension Attributes';
        addAttribute = document.createElement('button');
        addAttribute.type = 'button';
        addAttribute.className = 'button button-quiet';
        addAttribute.textContent = de ? 'ExtensionAttribute hinzufuegen' : 'Add extension attribute';
        addAttribute.addEventListener('click', () => {
          appendAttribute();
          refreshAttributeChoices();
          changed();
        });
        fieldset.append(title, attributeContainer, addAttribute);
        for (const [name, value] of Object.entries(rule?.extensionAttributes ?? {})) appendAttribute(name, value);
        refreshAttributeChoices();
        continue;
      }
      if (key === 'groupId' || key === 'groups' || key === 'administrativeUnitName') {
        const initial = key === 'groups' ? rule?.deviceGroupIds ?? []
          : key === 'groupId' ? (rule?.groupId ? [rule.groupId] : [])
          : rule?.administrativeUnitName ? [rule.administrativeUnitName] : [];
        objectPickers.set(key, mountObjectPicker(fieldset, initial,
          key === 'administrativeUnitName' ? searchAdministrativeUnits : searchGroups,
          language, labels[key],
          key === 'groups' ? 'deviceGroups' : key === 'groupId' ? 'userGroup' : 'administrativeUnit',
          changed));
        continue;
      }
      const label = document.createElement('label');
      label.className = 'field-label';
      label.append(document.createTextNode(labels[key]));
      const input = key === 'description' ? document.createElement('textarea') : document.createElement('input');
      if (key === 'description') input.maxLength = 2048;
      input.value = String(values[key]);
      input.autocomplete = 'off';
      label.append(input);
      fieldset.append(label);
      inputs.set(key, input);
      if (key === 'name') input.addEventListener('input', () => { summary.textContent = input.value.trim() || (de ? 'Neue Regel' : 'New rule'); });
    }
    const tagFeedback = document.createElement('p');
    tagFeedback.setAttribute('role', 'status');
    function checkTags(): boolean {
      const group = inputs.get('groupTag')!;
      const legacyUnchanged = original && !original.groupTag && group.value === original.tags.join(', ');
      const error = legacyUnchanged ? '' : validatePolicyTags(group.value);
      group.setCustomValidity(error);
      tagFeedback.textContent = error;
      return !error;
    }
    for (const key of ['groupTag'] as const) {
      inputs.get(key)!.addEventListener('input', checkTags);
    }
    inputs.get('groupTag')!.parentElement!.after(tagFeedback);
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'button button-quiet';
    remove.textContent = text.remove;
    const row = { element: details, dirty };
    const read = (): TagPolicyRule => {
      const fields = readFields();
      if (new Set(attributeRows.map(row => row.select.value)).size !== attributeRows.length) {
        details.open = true;
        throw new Error('Duplicate extension attribute.');
      }
      const tagsValid = checkTags();
      const invalidInput = Array.from(fieldset.querySelectorAll('input:not([type="search"])')).find(input =>
        input instanceof HTMLInputElement && !input.checkValidity());
      if (!tagsValid || invalidInput) {
        details.open = true;
        if (invalidInput instanceof HTMLInputElement) invalidInput.reportValidity();
        throw new Error(de ? 'Bitte die markierten Eingaben pruefen.' : 'Check the highlighted fields.');
      }
      try {
        return { ...parsePolicyFields(fields, original), ruleId: original?.ruleId ?? draftId };
      } catch (error) {
        details.open = true;
        throw error;
      }
    };
    async function persist(replacement?: TagPolicyRule): Promise<void> {
      if (busy) return;
      busy = true;
      load.disabled = add.disabled = true;
      list.inert = true;
      rowStatus.textContent = '';
      try {
        const latest = await request<{ policy: TagPolicyRule[] }>();
        const policy = updateSingleRule(latest.policy, original, replacement);
        const response = await request<{ policy: TagPolicyRule[] }>({ method: 'PUT', body: JSON.stringify({ policy }) });
        if (replacement) {
          const saved = response.policy.find(value => ruleKey(value) === ruleKey(replacement));
          if (!saved) throw new Error('Saved rule missing from server response. Reload policies.');
          original = saved;
          if (historyButton) historyButton.disabled = !saved.ruleId;
          inputs.get('groupTag')!.value = saved.groupTag ?? saved.tags.join(', ');
          checkTags();
          baseline = stableJson(readFields());
          save.hidden = true;
          window.alert(text.saved);
          rowStatus.textContent = text.saved;
        } else {
          rows = rows.filter(value => value !== row);
          details.remove();
        }
        await onSaved();
      } catch (error) {
        const target = details.isConnected ? rowStatus : status;
        target.textContent = error instanceof Error ? error.message : String(error);
      } finally {
        busy = false;
        load.disabled = add.disabled = false;
        list.inert = false;
      }
    }
    remove.addEventListener('click', () => {
      if (!window.confirm(text.confirm)) return;
      if (original) { void persist(); return; }
      rows = rows.filter(value => value !== row);
      details.remove();
    });
    save.addEventListener('click', () => {
      try { void persist(read()); }
      catch (error) { rowStatus.textContent = error instanceof Error ? error.message : String(error); }
    });
    fieldset.addEventListener('input', changed);
    fieldset.addEventListener('change', changed);
    fieldset.append(save, remove, rowStatus);
    details.append(summary, fieldset);
    list.append(details);
    rows.push(row);
    baseline = stableJson(readFields());
    changed();
    return details;
  }
  async function reload(): Promise<void> {
    if (busy) return;
    if (rows.some(row => row.dirty()) && !window.confirm(de ? 'Ungespeicherte Aenderungen verwerfen?' : 'Discard unsaved changes?')) return;
    busy = true;
    load.disabled = add.disabled = true;
    list.inert = true;
    status.textContent = de ? 'Aktuelle Policies werden geladen ...' : 'Loading current policies ...';
    try {
      const response = await request<{ policy: TagPolicyRule[] }>();
      rows = [];
      list.replaceChildren();
      response.policy.forEach(addRule);
      loaded = true;
      status.textContent = '';
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : String(error);
    } finally {
      busy = false;
      load.disabled = false;
      add.disabled = !loaded;
      list.inert = false;
    }
  }
  load.addEventListener('click', () => { void reload(); });
  add.addEventListener('click', () => {
    const details = addRule();
    details.scrollIntoView({ behavior: 'smooth', block: 'start' });
    details.querySelector('input')?.focus({ preventScroll: true });
  });
  container.append(heading, load, add, status, list);
  return { reload };
}
