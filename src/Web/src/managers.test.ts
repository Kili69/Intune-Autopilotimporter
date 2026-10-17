import { describe, expect, it, vi } from 'vitest';
import { InteractionRequiredAuthError } from '@azure/msal-browser';
import { ApiRequestError } from './api';
import { getManagerAdministrationAccess } from './managers';

describe('Manager administration visibility', () => {
  it('never requests ARM consent or manager data for a policy manager without Azure rights', async () => {
    const request = vi.fn();
    expect(await getManagerAdministrationAccess(
      async () => ({ canManagePolicyManagers: false }), request)).toBe('denied');
    expect(request).not.toHaveBeenCalled();
  });
  it('offers ARM sign-in only after the server confirms Owner/Contributor', async () => {
    expect(await getManagerAdministrationAccess(
      async () => ({ canManagePolicyManagers: true }),
      async () => { throw new InteractionRequiredAuthError('consent_required'); })).toBe('signInRequired');
  });
  it('shows the tab after both the server and delegated ARM checks succeed', async () => {
    expect(await getManagerAdministrationAccess(
      async () => ({ canManagePolicyManagers: true }), async () => ({}))).toBe('allowed');
  });
  it.each([401, 403])('hides the controls when delegated verification returns %s', async status => {
    expect(await getManagerAdministrationAccess(
      async () => ({ canManagePolicyManagers: true }),
      async () => { throw new ApiRequestError('Denied', status); })).toBe('denied');
  });
  it('surfaces server verification failures without requesting ARM consent', async () => {
    const request = vi.fn();
    await expect(getManagerAdministrationAccess(
      async () => { throw new ApiRequestError('Azure verification unavailable', 502); },
      request)).rejects.toThrow('Azure verification unavailable');
    expect(request).not.toHaveBeenCalled();
  });
  it('surfaces delegated dependency failures instead of displaying sign-in', async () => {
    await expect(getManagerAdministrationAccess(
      async () => ({ canManagePolicyManagers: true }),
      async () => { throw new ApiRequestError('ARM unavailable', 502); })).rejects.toThrow('ARM unavailable');
  });
  it('rejects malformed eligibility responses rather than trusting truthy data', async () => {
    const request = vi.fn();
    await expect(getManagerAdministrationAccess(
      async () => JSON.parse('{"canManagePolicyManagers":"false"}'), request)).rejects.toThrow('Invalid manager access response');
    expect(request).not.toHaveBeenCalled();
  });
});
