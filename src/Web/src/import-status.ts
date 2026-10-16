export interface ImportStatus {
  status?: string;
  deviceErrorName?: string | null;
  deviceErrorCode?: number | null;
  processingCompletedAtUtc?: string;
}

export function getImportError(record: ImportStatus): string | undefined {
  const name = record.deviceErrorName?.trim();
  if (name && name.toLowerCase() !== 'none') return name;
  if (record.deviceErrorCode != null && record.deviceErrorCode !== 0) {
    return String(record.deviceErrorCode);
  }
  return undefined;
}

export function getHistoryStatus(record: ImportStatus): 'pending' | 'complete' | 'error' {
  const normalized = record.status?.toLowerCase();
  if (getImportError(record) || normalized === 'error' || normalized === 'failed') return 'error';
  return record.processingCompletedAtUtc ? 'complete' : 'pending';
}
