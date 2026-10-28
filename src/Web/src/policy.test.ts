import { describe, expect, it } from 'vitest';
import { getMissingPolicyFields, getPolicyTagLabel, parsePolicyFields, PolicyFields, validatePolicyTags, validateExtensionAttributeValue, updateSingleRule } from './policy';

const fields: PolicyFields = {
  name: 'Sales',
  groupId: '11111111-1111-1111-1111-111111111111',
  groupTag: 'Sales',
  attributes: 'extensionAttribute1=Sales\nextensionAttribute5=Berlin',
  groups: '22222222-2222-2222-2222-222222222222',
  administrativeUnitName: '',
};

describe('Named policy editor', () => {
  it.each([
    { missing: [] },
    { missing: ['name'] },
    { missing: ['groupId'] },
    { missing: ['groupTag'] },
    { missing: ['name', 'groupId'] },
    { missing: ['name', 'groupTag'] },
    { missing: ['groupId', 'groupTag'] },
    { missing: ['name', 'groupId', 'groupTag'] },
  ] as const)('lists all missing required fields: $missing', ({ missing }) => {
    const input = { ...fields };
    for (const key of missing) input[key] = '   ';
    expect(getMissingPolicyFields(input)).toEqual(missing);
  });
  it('preserves free-text descriptions including line breaks', () => {
    expect(parsePolicyFields({ ...fields, description: 'Sales devices\nBerlin and Hamburg' }).description)
      .toBe('Sales devices\nBerlin and Hamburg');
    expect(parsePolicyFields({ ...fields, description: '' }).description).toBe('');
    expect(parsePolicyFields({ ...fields, description: 'x'.repeat(2048) }).description?.length).toBe(2048);
  });
  it('preserves the persistent rule identity through renames and field changes', () => {
    const original = { ...parsePolicyFields(fields), ruleId: '33333333-3333-3333-3333-333333333333' };
    const replacement = parsePolicyFields({ ...fields, name: 'Renamed', description: 'Updated' }, original);
    expect(replacement.ruleId).toBe(original.ruleId);
    expect(updateSingleRule([original], original, replacement)).toEqual([replacement]);
  });
  it('rejects duplicate names even when the rules have different persistent IDs', () => {
    const original = { ...parsePolicyFields(fields), ruleId: '33333333-3333-3333-3333-333333333333' };
    expect(() => updateSingleRule([original], undefined, { ...original, ruleId: '44444444-4444-4444-4444-444444444444' }))
      .toThrow('already exists');
  });
  it('rejects oversized descriptions and non-text control characters', () => {
    expect(() => parsePolicyFields({ ...fields, description: 'x'.repeat(2049) })).toThrow('description');
    expect(() => parsePolicyFields({ ...fields, description: 'Bad\u0000value' })).toThrow('description');
  });
  it('shows distinct rule names without tag values or generated GUID names', () => {
    expect(getPolicyTagLabel('Sales', [
      { name: 'Berlin', tags: ['Sales'] },
      { name: 'Berlin', tags: ['Sales'] },
      { name: 'London', tags: ['Sales'] },
      { name: 'Unrelated', tags: ['Other'] },
      { name: `Policy ${fields.groupId}`, tags: ['Sales'] },
    ])).toBe('Berlin / London');
  });
  it('uses the tag as a readable fallback for legacy or missing names', () => {
    expect(getPolicyTagLabel('Sales', [{ name: `Policy ${fields.groupId}`, tags: ['Sales'] }])).toBe('Sales');
    expect(getPolicyTagLabel('Sales')).toBe('Sales');
  });
  it('requires a Group Tag and preserves individual attribute values without scope actions', () => {
    const rule = parsePolicyFields(fields);
    expect(rule).not.toHaveProperty('scopeTag');
    expect(rule.extensionAttributes).toEqual({ extensionAttribute1: 'Sales', extensionAttribute5: 'Berlin' });
    expect(rule.deviceGroupIds).toEqual(['22222222-2222-2222-2222-222222222222']);
  });
  it('rejects a missing group tag', () => {
    expect(() => parsePolicyFields({ ...fields, groupTag: '' })).toThrow('Group Tag');
  });
  it.each([
    { name: '' }, { groupTag: '' }, { groupId: 'bad' }, { groupId: '' },
    { groupId: '00000000-0000-0000-0000-000000000000' },
    { groupId: `${fields.groupId},${fields.groupId}` },
    { attributes: 'extensionAttribute16=bad' },
    { attributes: 'extensionAttribute1=A\nextensionAttribute1=B' },
    { groups: 'not-a-guid' }, { groups: '00000000-0000-0000-0000-000000000000' },
  ])('rejects invalid fields %j', changes => {
    expect(() => parsePolicyFields({ ...fields, ...changes })).toThrow();
  });
  it('preserves an unchanged multi-tag legacy rule without introducing scope tag actions', () => {
    const legacy = { groupId: fields.groupId, tags: ['A', 'B'], scopeTag: 'Obsolete' };
    const result = parsePolicyFields({ ...fields, groupTag: 'A, B', attributes: '', groups: '' }, legacy);
    expect(result.tags).toEqual(['A', 'B']);
    expect(result).not.toHaveProperty('scopeTag');
    expect(result.extensionAttributes).toBeUndefined();
  });
  it('does not write any attributes when none are entered', () => {
    expect(parsePolicyFields({ ...fields, attributes: '' }).extensionAttributes).toEqual({});
  });
  it('preserves all 15 attribute choices and single-line values', () => {
    const attributes = Object.fromEntries(Array.from({ length: 15 }, (_, index) =>
      [`extensionAttribute${index + 1}`, `Value=${index + 1}`]));
    expect(parsePolicyFields({ ...fields, attributes }).extensionAttributes).toEqual(attributes);
  });
  it('preserves an explicit empty attribute map', () => {
    expect(parsePolicyFields({ ...fields, attributes: {} }).extensionAttributes).toEqual({});
  });

  describe('Saving individual rules', () => {
    const original = parsePolicyFields(fields);
    const other = { ...original, name: 'Other', groupTag: 'Other', tags: ['Other'] };
    it('updates only the chosen rule and preserves the latest other rules', () => {
      const changedOther = { ...other, groupTag: 'Changed remotely' };
      const replacement = { ...original, name: 'Renamed', extensionAttributes: {} };
      expect(updateSingleRule([original, changedOther], original, replacement)).toEqual([replacement, changedOther]);
    });
    it('adds a rule without including unsaved local drafts', () => {
      expect(updateSingleRule([original], undefined, other)).toEqual([original, other]);
    });
    it('rejects stale or deleted original rules', () => {
      expect(() => updateSingleRule([{ ...original, groupTag: 'Remote' }], original, other)).toThrow('changed on the server');
      expect(() => updateSingleRule([other], original, original)).toThrow('changed on the server');
    });
    it('rejects duplicate rule identities including case-only differences', () => {
      expect(() => updateSingleRule([original, other], original, { ...other, name: 'OTHER' })).toThrow('already exists');
    });
    it('removes only the chosen rule and prevents deleting the last rule', () => {
      expect(updateSingleRule([original, other], original)).toEqual([other]);
      expect(() => updateSingleRule([original], original)).toThrow('At least one rule');
    });
    it('compares objects without depending on property serialization order', () => {
      const reordered = { ...original, extensionAttributes: { extensionAttribute5: 'Berlin', extensionAttribute1: 'Sales' } };
      expect(updateSingleRule([reordered, other], original, original)).toEqual([original, other]);
    });
  });
  it('rejects an out-of-range attribute selected outside the editor', () => {
    expect(() => parsePolicyFields({ ...fields, attributes: { extensionAttribute16: 'bad' } })).toThrow();
  });
  it('rejects attribute values exceeding the Entra limit', () => {
    expect(() => parsePolicyFields({ ...fields, attributes: { extensionAttribute1: 'a'.repeat(1025) } })).toThrow();
  });
  it.each(['\n', '\r', '\t', '\0', '\u007f', '\u0085', '\u2028', '\u2029'])(
    'rejects non-single-line/control characters %j', character => {
      expect(validateExtensionAttributeValue(`A${character}B`)).not.toBe('');
      expect(() => parsePolicyFields({ ...fields, attributes: { extensionAttribute1: `A${character}B` } })).toThrow();
    },
  );
  it('accepts the exact length limit, empty values, Unicode and punctuation', () => {
    for (const value of ['', 'a'.repeat(1024), 'München & 東京 / "IT" = 😀']) {
      expect(validateExtensionAttributeValue(value)).toBe('');
    }
    expect(validateExtensionAttributeValue('a'.repeat(1025))).not.toBe('');
  });
  it('converts a legacy single-tag rule when configuring an explicit attribute map', () => {
    const legacy = { groupId: fields.groupId, tags: ['Sales'] };
    const rule = parsePolicyFields({ ...fields, attributes: {}, groups: '' }, legacy);
    expect(rule.groupTag).toBe('Sales');
    expect(rule.extensionAttributes).toEqual({});
  });
  it('requires a single Group Tag before converting a multi-tag legacy rule', () => {
    const legacy = { groupId: fields.groupId, tags: ['A', 'B'] };
    expect(() => parsePolicyFields({ ...fields, groupTag: 'A, B', attributes: {}, groups: '' }, legacy)).toThrow();
  });
  it.each(['Sales Berlin', 'München & Zürich', 'Ops+IT@HQ', '部門', 'A/B: C', 'Scope "quoted"'])(
    'does not invent a character whitelist for %s', value => {
      expect(validatePolicyTags(value)).toBe('');
    },
  );
  it('validates required Group Tag and its project limits', () => {
    expect(validatePolicyTags('')).not.toBe('');
    expect(validatePolicyTags('a'.repeat(128))).toBe('');
    expect(validatePolicyTags('a'.repeat(129))).not.toBe('');
    expect(validatePolicyTags('A,B')).not.toBe('');
  });
});
