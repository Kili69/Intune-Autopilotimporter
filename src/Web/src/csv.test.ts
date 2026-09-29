import { describe, expect, it } from 'vitest';
import { isValidBase64, parseAutopilotCsv } from './csv';
import { buildHistoryRequestUrl, formatHashReference } from './history';

const hash = btoa('hardware-hash');

describe('parseAutopilotCsv', () => {
  it('reads a standard Autopilot CSV', () => {
    const devices = parseAutopilotCsv(
      `Device Serial Number,Windows Product ID,Hardware Hash\nPC-001,,${hash}\n`,
    );

    expect(devices).toEqual([{ serialNumber: 'PC-001', hardwareIdentifier: hash }]);
  });

  it('supports quoted CSV values and a UTF-8 BOM', () => {
    const devices = parseAutopilotCsv(
      `\uFEFFDevice Serial Number,Hardware Hash\n"PC,002","${hash}"`,
    );

    expect(devices[0]?.serialNumber).toBe('PC,002');
  });

  it('rejects missing columns and invalid hashes', () => {
    expect(() => parseAutopilotCsv('Device Serial Number\nPC-001')).toThrow('Spalten fehlen');
    expect(() => parseAutopilotCsv('Device Serial Number,Hardware Hash\nPC-001,invalid')).toThrow('Base64');
  });
});

describe('isValidBase64', () => {
  it('accepts non-empty Base64 only', () => {
    expect(isValidBase64(hash)).toBe(true);
    expect(isValidBase64('')).toBe(false);
    expect(isValidBase64('%%%')).toBe(false);
  });
});

describe('history helpers', () => {
  it('adds the manager-wide history flag only when requested', () => {
    expect(buildHistoryRequestUrl('https://example.test/api/management/imports', false))
      .toBe('https://example.test/api/management/imports?top=25');
    expect(buildHistoryRequestUrl('https://example.test/api/management/imports', true))
      .toBe('https://example.test/api/management/imports?top=25&showAll=true');
  });

  it('shortens long hash values for the audit table', () => {
    expect(formatHashReference('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'))
      .toBe('012345…abcdef');
    expect(formatHashReference('   abc   ')).toBe('abc');
    expect(formatHashReference('')).toBe('—');
  });
});
