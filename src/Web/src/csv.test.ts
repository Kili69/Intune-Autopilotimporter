import { describe, expect, it } from 'vitest';
import { isValidBase64, parseAutopilotCsv } from './csv';

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
