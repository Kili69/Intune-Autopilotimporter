import Papa from 'papaparse';

export interface AutopilotDevice {
  serialNumber: string;
  hardwareIdentifier: string;
}

interface AutopilotCsvRow {
  'Device Serial Number'?: string;
  'Hardware Hash'?: string;
}

export function isValidBase64(value: string): boolean {
  if (!value || value.length > 65_536 || value.length % 4 !== 0) return false;
  try {
    return atob(value).length > 0;
  } catch {
    return false;
  }
}

export function parseAutopilotCsv(csv: string): AutopilotDevice[] {
  const result = Papa.parse<AutopilotCsvRow>(csv, {
    header: true,
    skipEmptyLines: 'greedy',
    transformHeader: (header) => header.replace(/^\uFEFF/, '').trim(),
  });

  const fields = result.meta.fields ?? [];
  const required = ['Device Serial Number', 'Hardware Hash'];
  const missing = required.filter((field) => !fields.includes(field));
  if (missing.length > 0) {
    throw new Error(`Erforderliche CSV-Spalten fehlen: ${missing.join(', ')}.`);
  }

  if (result.errors.length > 0) {
    const error = result.errors[0];
    throw new Error(`CSV konnte nicht gelesen werden${error?.row !== undefined ? ` (Zeile ${error.row + 2})` : ''}.`);
  }

  if (result.data.length === 0) throw new Error('Die CSV enthält keine Geräte.');

  return result.data.map((row, index) => {
    const serialNumber = row['Device Serial Number']?.trim() ?? '';
    const hardwareIdentifier = row['Hardware Hash']?.trim() ?? '';
    const line = index + 2;
    if (!serialNumber) throw new Error(`Zeile ${line} enthält keine Seriennummer.`);
    if (serialNumber.length > 128) throw new Error(`Die Seriennummer in Zeile ${line} ist zu lang.`);
    if (!hardwareIdentifier) throw new Error(`Zeile ${line} enthält keinen Hardware Hash.`);
    if (!isValidBase64(hardwareIdentifier)) {
      throw new Error(`Zeile ${line} enthält keinen gültigen Base64 Hardware Hash.`);
    }
    return { serialNumber, hardwareIdentifier };
  });
}
