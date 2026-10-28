import { describe, expect, it } from 'vitest';
import { applyCompletedTagChanges } from './tag-changes';

describe('Completed tag changes in the device list', () => {
  const device = { id: 'CD1F0BDF-0000-0000-0000-000000000001', serialNumber: '1', groupTag: 'PAW' };

  it('shows the confirmed tag while Autopilot still reports the previous tag', () => {
    const [result] = applyCompletedTagChanges([device], [
      { deviceId: device.id.toLowerCase(), previousGroupTag: 'paw', groupTag: 'VIP' },
    ]);
    expect(result?.groupTag).toBe('VIP');
    expect(device.groupTag).toBe('PAW');
  });

  it('keeps tags that changed independently or devices without a change', () => {
    const other = { ...device, id: 'other' };
    const result = applyCompletedTagChanges([{ ...device, groupTag: 'Sales' }, other], [
      { deviceId: device.id, previousGroupTag: 'PAW', groupTag: 'VIP' },
    ]);
    expect(result.map((item) => item.groupTag)).toEqual(['Sales', 'PAW']);
  });
});
