import { describe, expect, it } from 'vitest';
import { getHistoryStatus, getImportError, getImportTimeline } from './import-status';
import { ApiRequestError, canManageTagPolicies } from './api';

describe('Detailed operation timeline', () => {
  const at = (second: number): string => `2026-10-16T12:00:${String(second).padStart(2, '0')}Z`;
  it('shows the actual chronological import steps and applied values', () => {
    const steps = getImportTimeline({
      requestReceivedAtUtc: at(0), graphImportCreatedAtUtc: at(1), queuedAtUtc: at(2),
      processingStartedAtUtc: at(3), graphImportCompletedAtUtc: at(4),
      autopilotGroupTagUpdatedAtUtc: at(5), groupTag: 'Sales',
      entraDeviceResolvedAtUtc: at(6), entraDeviceId: 'device-id',
      extensionAttributeUpdatedAtUtc: at(7), appliedExtensionAttributes: { extensionAttribute5: 'Berlin' },
      deviceGroupsUpdatedAtUtc: at(8), targetDeviceGroupIds: ['target'], addedDeviceGroupIds: ['target'],
      removedDeviceGroupIds: ['old'], administrativeUnitAssignedAtUtc: at(9),
      administrativeUnitName: 'Berlin Devices', removedAdministrativeUnits: ['Old AU'],
      processingCompletedAtUtc: at(10),
    }, 'de');
    expect(steps.map(step => step.title)).toEqual([
      'Import gestartet', 'Device Hash an Autopilot übermittelt', 'Entra-Konfiguration zur Verarbeitung eingereiht',
      'Hintergrundverarbeitung gestartet', 'Device Hash importiert', 'Group Tag gesetzt', 'Gerät in Entra ID gefunden',
      'Extension Attributes gesetzt', 'Gerät zu Entra-Gruppen hinzugefügt', 'Administrative Unit zugewiesen', 'Vorgang abgeschlossen',
    ]);
    expect(steps[7]?.detail).toContain('extensionAttribute5 = Berlin');
    expect(steps[8]?.detail).toContain('Entfernt aus: old');
    expect(steps[9]?.detail).toContain('Berlin Devices');
    expect(steps[9]?.detail).toContain('Old AU');
    expect(steps[2]?.detail).toContain('noch keine Erfolgsmeldung');
  });
  it('does not invent completed actions from queued work or a legacy record', () => {
    const steps = getImportTimeline({ graphImportCreatedAtUtc: at(0), queuedAtUtc: at(1), groupTag: 'Sales' }, 'de');
    expect(steps.map(step => step.title)).toEqual([
      'Device Hash an Autopilot übermittelt', 'Group Tag mit Import übermittelt', 'Entra-Konfiguration zur Verarbeitung eingereiht',
    ]);
    expect(steps[1]?.detail).toContain('keine separate Bestätigung');
    const legacy = getImportTimeline({ extensionAttributeUpdatedAtUtc: at(3) }, 'de');
    expect(legacy[0]?.detail).toContain('älteren Vorgang');
  });
  it('distinguishes skipped attributes and unchanged group/AU checks from assignments', () => {
    const steps = getImportTimeline({
      processingCompletedAtUtc: at(3), appliedExtensionAttributes: {}, deviceGroupsUpdatedAtUtc: at(1),
      targetDeviceGroupIds: [], addedDeviceGroupIds: [], administrativeUnitAssignedAtUtc: at(2),
      administrativeUnitName: '',
    }, 'de');
    expect(steps.map(step => step.title)).toEqual([
      'Entra-Gruppenmitgliedschaften abgeglichen', 'Administrative-Unit-Mitgliedschaften abgeglichen',
      'Extension Attributes übersprungen', 'Vorgang abgeschlossen',
    ]);
    expect(steps[0]?.detail).toContain('keine');
    expect(steps[1]?.detail).toContain('Keine Ziel-AU');
  });
  it('localizes re-tagging and sorts by recorded time instead of assumed operation order', () => {
    const steps = getImportTimeline({
      operationType: 'tagChange', requestReceivedAtUtc: at(0),
      entraDeviceResolvedAtUtc: at(2), autopilotGroupTagUpdatedAtUtc: at(1), groupTag: 'New',
    }, 'en');
    expect(steps.map(step => step.title)).toEqual(['Group Tag change started', 'Group Tag applied', 'Device found in Entra ID']);
    expect(steps[1]?.detail).toContain('Autopilot accepted');
  });
  it('does not show any steps without recorded evidence', () => {
    expect(getImportTimeline({}, 'en')).toEqual([]);
  });
});

describe('Import history error state', () => {
  it.each(['None', 'none', ' NONE ', '', null, undefined])('does not treat %j with code zero as an error', deviceErrorName => {
    const record = { status: 'complete', deviceErrorCode: 0, deviceErrorName, processingCompletedAtUtc: '2026-10-16T12:54:30Z' };
    expect(getImportError(record)).toBeUndefined();
    expect(getHistoryStatus(record)).toBe('complete');
  });
  it('keeps a successful Graph import pending until the worker completes', () => {
    expect(getHistoryStatus({ status: 'complete', deviceErrorName: 'None', deviceErrorCode: 0 })).toBe('pending');
  });
  it.each([
    { deviceErrorName: 'DeviceAlreadyAssigned', deviceErrorCode: 808 },
    { deviceErrorName: 'None', deviceErrorCode: 808 },
    { deviceErrorCode: 808 },
    { status: 'error', deviceErrorName: 'None', deviceErrorCode: 0 },
    { status: 'failed' },
  ])('preserves actual errors %j even when a completion timestamp exists', record => {
    expect(getHistoryStatus({ ...record, processingCompletedAtUtc: '2026-10-16T12:54:30Z' })).toBe('error');
  });
  it('uses the real code instead of the None sentinel for an actual error', () => {
    expect(getImportError({ deviceErrorName: 'None', deviceErrorCode: 808 })).toBe('808');
  });
  it('reports unresolved background processing failures', () => {
    const record = {
      status: 'complete',
      deviceErrorCode: 0,
      deviceErrorName: 'None',
      processingErrorAtUtc: '2026-10-19T06:00:00Z',
      processingFailedAtUtc: '2026-10-19T06:00:00Z',
      processingError: 'HTTP 403: denied',
      processingErrorStep: 'extensionAttributes',
    };
    expect(getHistoryStatus(record)).toBe('error');
    expect(getImportError(record, 'en')).toContain('HTTP 403: denied');
  });
  it('clears the failure once a later attempt completes', () => {
    const record = {
      status: 'complete',
      deviceErrorCode: 0,
      deviceErrorName: 'None',
      processingErrorAtUtc: '2026-10-19T06:00:00Z',
      processingFailedAtUtc: '2026-10-19T06:00:00Z',
      processingError: 'HTTP 403: denied',
      processingErrorStep: 'extensionAttributes',
      processingCompletedAtUtc: '2026-10-19T07:00:00Z',
    };
    expect(getHistoryStatus(record)).toBe('complete');
    expect(getImportError(record, 'en')).toBeUndefined();
    expect(getImportTimeline(record, 'en').map(step => step.title)).toContain('Error, later retried successfully');
  });
});

describe('Policy manager access probe', () => {
  it('allows the tab only after a successful authorized manager GET', async () => {
    expect(await canManageTagPolicies(async () => ({ policy: [] }))).toBe(true);
  });
  it('hides the tab for a forbidden response', async () => {
    expect(await canManageTagPolicies(async () => { throw new ApiRequestError('not authorized', 403); })).toBe(false);
  });
  it.each([401, 500, 502, 503])('reports HTTP %s instead of silently treating it as missing permission', async status => {
    const error = new ApiRequestError('dependency unavailable', status);
    await expect(canManageTagPolicies(async () => { throw error; })).rejects.toBe(error);
  });
  it('reports network failures', async () => {
    const error = new TypeError('network failed');
    await expect(canManageTagPolicies(async () => { throw error; })).rejects.toBe(error);
  });
});
