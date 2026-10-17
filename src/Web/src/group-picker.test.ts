import { describe, expect, it } from 'vitest';
import { validateObjectSearch } from './group-picker';

describe('Object picker search validation', () => {
  it.each(['', 'a', '  ', ' a ', 'a'.repeat(129)])('rejects invalid lengths %j', value => {
    expect(validateObjectSearch(value)).not.toBe('');
  });
  it.each(['\n', '\r', '\t', '\0', '\u007f', '\u0085', '\u200b', '\u2028', '\u2029', '\u202e'])(
    'rejects control and invisible formatting characters %j', character => {
      expect(validateObjectSearch(`Sales${character}Berlin`)).not.toBe('');
    },
  );
  it.each(['IT', ' Sales ', 'a'.repeat(128), "O'Brien", 'München & 東京 / IT', 'user@example.com',
    '11111111-1111-1111-1111-111111111111'])('preserves valid names and object IDs %j', value => {
    expect(validateObjectSearch(value)).toBe('');
  });
});
