import { describe, expect, it } from 'vitest';
import { describeManagementChanges, managementEventStatus } from './management-history';

describe('Management event status', () => {
  it.each(['requested', 'applied'] as const)('labels %s as Information, not as completion status', stage => {
    expect(managementEventStatus(stage)).toBe('Information');
  });
  it('labels failure events as Error', () => {
    expect(managementEventStatus('failed')).toBe('Error');
  });
});

describe('Management change details', () => {
  it('shows changed descriptions and nested attribute values with old and new values', () => {
    expect(describeManagementChanges(
      { description: 'Old', extensionAttributes: { extensionAttribute1: 'A' } },
      { description: 'New', extensionAttributes: { extensionAttribute1: 'B' } },
    )).toEqual(['description: "Old" → "New"', 'extensionAttributes.extensionAttribute1: "A" → "B"']);
  });
  it('identifies policies by name and group instead of their list positions', () => {
    const first = { name: 'Sales', groupId: 'one', description: 'Old' };
    const second = { name: 'Engineering', groupId: 'two' };
    expect(describeManagementChanges([first, second], [second, { ...first, description: 'New' }]))
      .toEqual(['one / Sales.description: "Old" → "New"']);
  });
  it('includes added/deleted rules and changed manager IDs', () => {
    expect(describeManagementChanges({ additionalPrincipalIds: ['old'] }, { additionalPrincipalIds: ['new'] }))
      .toEqual(['additionalPrincipalIds: ["old"] → ["new"]']);
    expect(describeManagementChanges([], [{ name: 'New', groupId: 'id' }])[0]).toContain('id / New');
    expect(describeManagementChanges([{ name: 'Old', groupId: 'id' }], [])[0]).toContain('id / Old');
  });
  it('does not manufacture changes for equivalent nested values', () => {
    expect(describeManagementChanges({ nested: { a: 1, b: 2 } }, { nested: { b: 2, a: 1 } })).toEqual([]);
  });
});
