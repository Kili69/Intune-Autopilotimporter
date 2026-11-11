import { describe, expect, it } from 'vitest';
import { applyCompletedTagChanges, formatDeviceExtensionAttributes } from './tag-changes';

describe('Current Entra extension attributes', () => {
  it('shows populated attributes by name in numeric order without changing their values', () => {
    expect(formatDeviceExtensionAttributes({
      extensionAttribute10: 'Berlin & Hamburg',
      extensionAttribute2: '<Sales>',
      extensionAttribute1: 'Current value',
      extensionAttribute3: null,
      extensionAttribute4: '',
    })).toBe('extensionAttribute1 = Current value; extensionAttribute2 = <Sales>; extensionAttribute10 = Berlin & Hamburg');
  });

  const emptyAttributes: Array<Record<string, string | null> | null | undefined> = [
    undefined, null, {}, { extensionAttribute1: null, extensionAttribute2: '' },
  ];
  it.each(emptyAttributes)(
    'leaves devices without populated attributes empty (%j)',
    (attributes) => {
      expect(formatDeviceExtensionAttributes(attributes)).toBe('');
    },
  );
});

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

  it('keeps current Entra attributes separate from a completed Intune tag change', () => {
    const attributes = { extensionAttribute1: 'Actual Entra value' };
    const [result] = applyCompletedTagChanges([{ ...device, extensionAttributes: attributes }], [
      { deviceId: device.id, previousGroupTag: 'PAW', groupTag: 'VIP' },
    ]);
    expect(result?.groupTag).toBe('VIP');
    expect(result?.extensionAttributes).toEqual(attributes);
  });
});
