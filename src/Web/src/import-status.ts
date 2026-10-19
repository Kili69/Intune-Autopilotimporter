export interface ImportStatus {
  status?: string;
  deviceErrorName?: string | null;
  deviceErrorCode?: number | null;
  processingCompletedAtUtc?: string;
  processingFailedAtUtc?: string | null;
  processingError?: string | null;
}

export interface ImportTimelineRecord {
  operationType?: string;
  groupTag?: string;
  requestReceivedAtUtc?: string;
  graphImportCreatedAtUtc?: string;
  graphImportCompletedAtUtc?: string;
  queuedAtUtc?: string;
  processingStartedAtUtc?: string;
  entraDeviceResolvedAtUtc?: string;
  entraDeviceId?: string;
  autopilotGroupTagUpdatedAtUtc?: string;
  extensionAttributeUpdatedAtUtc?: string;
  appliedExtensionAttributes?: Record<string, string>;
  deviceGroupsUpdatedAtUtc?: string;
  targetDeviceGroupIds?: string[];
  addedDeviceGroupIds?: string[];
  removedDeviceGroupIds?: string[];
  administrativeUnitAssignedAtUtc?: string;
  administrativeUnitName?: string;
  removedAdministrativeUnits?: string[];
  processingCompletedAtUtc?: string;
  processingErrorAtUtc?: string | null;
  processingFailedAtUtc?: string | null;
  processingError?: string | null;
  processingErrorStep?: string | null;
  processingAttempt?: number | null;
  processingMaxAttempts?: number | null;
}

const processingStepLabels: Record<string, [string, string]> = {
  policy: ['Regel auswerten', 'Evaluate rule'],
  graphToken: ['Microsoft-Graph-Token', 'Microsoft Graph token'],
  autopilotGroupTag: ['Group Tag setzen', 'Apply Group Tag'],
  autopilotRegistration: ['Autopilot-Registrierung', 'Autopilot registration'],
  entraDevice: ['Entra-Gerät suchen', 'Find Entra device'],
  extensionAttributes: ['Extension Attributes setzen', 'Apply extension attributes'],
  deviceGroups: ['Entra-Gruppen abgleichen', 'Reconcile Entra groups'],
  administrativeUnits: ['Administrative Units abgleichen', 'Reconcile administrative units'],
  completion: ['Abschluss', 'Completion'],
};

export function getProcessingFailureDetail(record: ImportTimelineRecord, language: 'de' | 'en'): string {
  const de = language === 'de';
  const step = record.processingErrorStep
    ? (processingStepLabels[record.processingErrorStep]?.[de ? 0 : 1] ?? record.processingErrorStep)
    : undefined;
  const attempt = record.processingAttempt
    ? `${de ? 'Versuch' : 'Attempt'} ${record.processingAttempt}${record.processingMaxAttempts ? `/${record.processingMaxAttempts}` : ''}`
    : undefined;
  const prefix = [step, attempt].filter(Boolean).join(', ');
  return `${prefix ? `${prefix}: ` : ''}${record.processingError ?? ''}`.trim();
}

function isProcessingFailed(record: ImportStatus): boolean {
  if (!record.processingFailedAtUtc) return false;
  return !record.processingCompletedAtUtc ||
    Date.parse(record.processingCompletedAtUtc) < Date.parse(record.processingFailedAtUtc);
}

export function getImportTimeline(record: ImportTimelineRecord, language: 'de' | 'en'): Array<{
  title: string; detail: string; timestamp: string;
}> {
  const de = language === 'de';
  const text = (german: string, english: string): string => de ? german : english;
  const steps: Array<{ title: string; detail: string; timestamp: string }> = [];
  const add = (timestamp: string | undefined, title: string, detail: string): void => {
    if (timestamp) steps.push({ timestamp, title, detail });
  };
  const unknown = text('Für diesen älteren Vorgang wurden keine Aktionsdetails gespeichert.',
    'No action details were stored for this older operation.');
  add(record.requestReceivedAtUtc,
    record.operationType === 'tagChange' ? text('Group-Tag-Änderung gestartet', 'Group Tag change started') : text('Import gestartet', 'Import started'),
    text('Die autorisierte Anfrage wurde vom Importdienst angenommen.', 'The authorized request was accepted by the import service.'));
  add(record.graphImportCreatedAtUtc, text('Device Hash an Autopilot übermittelt', 'Device hash submitted to Autopilot'),
    text('Microsoft Graph hat den Import angenommen. Die Registrierung erfolgt asynchron und ist hier noch nicht abgeschlossen.',
      'Microsoft Graph accepted the import. Registration is asynchronous and is not yet complete at this step.'));
  if (record.graphImportCreatedAtUtc && !record.autopilotGroupTagUpdatedAtUtc) {
    add(record.graphImportCreatedAtUtc, text('Group Tag mit Import übermittelt', 'Group Tag submitted with import'),
      `${record.groupTag ?? '—'}. ${text('Im Importauftrag enthalten; keine separate Bestätigung des gesetzten Tags gespeichert.',
        'Included in the import request; no separate confirmation of the applied tag was stored.')}`);
  }
  add(record.queuedAtUtc, text('Entra-Konfiguration zur Verarbeitung eingereiht', 'Entra configuration queued'),
    text('Der Hintergrundprozess wartet auf die Autopilot-Registrierung und das Entra-Gerät. Danach verarbeitet er die konfigurierten Extension Attributes, Gruppen und Administrative Unit. Dies ist noch keine Erfolgsmeldung für diese Aktionen.',
      'The background worker waits for Autopilot registration and the Entra device, then processes the configured extension attributes, groups and administrative unit. This does not yet indicate that those actions succeeded.'));
  add(record.processingStartedAtUtc, text('Hintergrundverarbeitung gestartet', 'Background processing started'),
    text('Der Worker prüft die Geräteverfügbarkeit. Falls nötig wird der Auftrag automatisch erneut versucht.',
      'The worker checks device availability. The job is retried automatically when necessary.'));
  add(record.graphImportCompletedAtUtc, text('Device Hash importiert', 'Device hash imported'),
    text('Autopilot hat den Import abgeschlossen und eine registrierte Geräteidentität bereitgestellt.',
      'Autopilot completed the import and provided a registered device identity.'));
  add(record.autopilotGroupTagUpdatedAtUtc, text('Group Tag gesetzt', 'Group Tag applied'),
    `${record.groupTag ?? '—'}. ${record.operationType === 'tagChange'
      ? text('Autopilot hat die Aktualisierung angenommen.', 'Autopilot accepted the update.')
      : text('Am registrierten Autopilot-Gerät bestätigt.', 'Confirmed on the registered Autopilot device.')}`);
  add(record.entraDeviceResolvedAtUtc, text('Gerät in Entra ID gefunden', 'Device found in Entra ID'),
    record.entraDeviceId ? `Entra Device ID: ${record.entraDeviceId}` : unknown);
  const attributes = record.appliedExtensionAttributes;
  if (record.extensionAttributeUpdatedAtUtc) {
    add(record.extensionAttributeUpdatedAtUtc, text('Extension Attributes gesetzt', 'Extension attributes applied'),
      attributes ? Object.entries(attributes).map(([key, value]) => `${key} = ${value || '""'}`).join('; ') : unknown);
  } else if (attributes && !Object.keys(attributes).length) {
    add(record.processingCompletedAtUtc, text('Extension Attributes übersprungen', 'Extension attributes skipped'),
      text('Die Regel enthält keine Extension Attributes; es wurden keine Attribute geschrieben.',
        'The rule contains no extension attributes; no attributes were written.'));
  }
  const groupDetails: string[] = [];
  if (record.targetDeviceGroupIds) groupDetails.push(text('Zielgruppen (Mitgliedschaft sichergestellt): ', 'Target groups (membership ensured): ') +
    (record.targetDeviceGroupIds.join(', ') || text('keine', 'none')));
  if (record.addedDeviceGroupIds?.length) groupDetails.push(text('Hinzugefügt: ', 'Added: ') + record.addedDeviceGroupIds.join(', '));
  if (record.removedDeviceGroupIds?.length) groupDetails.push(text('Entfernt aus: ', 'Removed from: ') + record.removedDeviceGroupIds.join(', '));
  add(record.deviceGroupsUpdatedAtUtc, record.addedDeviceGroupIds?.length
    ? text('Gerät zu Entra-Gruppen hinzugefügt', 'Device added to Entra groups')
    : text('Entra-Gruppenmitgliedschaften abgeglichen', 'Entra group memberships reconciled'),
  groupDetails.join('; ') || unknown);
  const auDetails: string[] = [];
  if (record.administrativeUnitName != null) auDetails.push(record.administrativeUnitName ||
    text('Keine Ziel-AU konfiguriert.', 'No target AU configured.'));
  if (record.removedAdministrativeUnits?.length) auDetails.push(text('Entfernt aus: ', 'Removed from: ') + record.removedAdministrativeUnits.join(', '));
  add(record.administrativeUnitAssignedAtUtc, record.administrativeUnitName
    ? text('Administrative Unit zugewiesen', 'Administrative unit assigned')
    : text('Administrative-Unit-Mitgliedschaften abgeglichen', 'Administrative unit memberships reconciled'),
  auDetails.join('; ') || unknown);
  if (record.processingErrorAtUtc && record.processingError && !isProcessingFailed(record)) {
    add(record.processingErrorAtUtc, record.processingCompletedAtUtc &&
      Date.parse(record.processingCompletedAtUtc) > Date.parse(record.processingErrorAtUtc)
      ? text('Fehler, später erfolgreich wiederholt', 'Error, later retried successfully')
      : text('Fehler, wird automatisch erneut versucht', 'Error, retrying automatically'),
    getProcessingFailureDetail(record, language));
  }
  add(record.processingCompletedAtUtc, text('Vorgang abgeschlossen', 'Operation completed'),
    text('Alle für diesen Vorgang konfigurierten Schritte wurden erfolgreich verarbeitet. Dies ist keine Windows-Installation oder Intune-Einschreibung.',
      'All steps configured for this operation were processed successfully. This is not Windows installation or Intune enrollment.'));
  return steps.sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
}

export function getImportError(record: ImportStatus & ImportTimelineRecord, language: 'de' | 'en' = 'en'): string | undefined {
  const name = record.deviceErrorName?.trim();
  if (name && name.toLowerCase() !== 'none') return name;
  if (record.deviceErrorCode != null && record.deviceErrorCode !== 0) {
    return String(record.deviceErrorCode);
  }
  if (isProcessingFailed(record) && record.processingError) {
    return getProcessingFailureDetail(record, language);
  }
  return undefined;
}

export function getHistoryStatus(record: ImportStatus): 'pending' | 'complete' | 'error' {
  const normalized = record.status?.toLowerCase();
  if (getImportError(record) || normalized === 'error' || normalized === 'failed' || isProcessingFailed(record)) return 'error';
  return record.processingCompletedAtUtc ? 'complete' : 'pending';
}

// Summarizes an unfinished operation for live status polling: the worker has
// started once processingStartedAtUtc is recorded, and the newest recorded
// step describes the current progress.
export function getOperationProgress(
  record: ImportTimelineRecord & { processingStage?: string; status?: string },
  language: 'de' | 'en',
): { state: 'pending' | 'processing'; detail?: string } {
  const state = record.processingStage === 'processing' || record.processingStartedAtUtc ? 'processing' : 'pending';
  const steps = getImportTimeline(record, language);
  return { state, detail: steps[steps.length - 1]?.title ?? record.status };
}
