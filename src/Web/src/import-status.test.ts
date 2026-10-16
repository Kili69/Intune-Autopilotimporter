import { describe, expect, it } from 'vitest';
import { getHistoryStatus, getImportError } from './import-status';
import { ApiRequestError, canManageTagPolicies } from './api';

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
