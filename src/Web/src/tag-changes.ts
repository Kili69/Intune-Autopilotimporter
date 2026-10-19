export interface CompletedTagChange {
  deviceId: string;
  previousGroupTag: string;
  groupTag: string;
}

// Intune reports a changed Autopilot groupTag only after a delay. Show the
// confirmed destination while the device still reports the previous tag.
export function applyCompletedTagChanges<T extends { id: string; groupTag: string }>(
  devices: T[],
  changes: CompletedTagChange[],
): T[] {
  const byDevice = new Map(changes.map((change) => [change.deviceId.toLowerCase(), change]));
  return devices.map((device) => {
    const change = byDevice.get(device.id.toLowerCase());
    if (!change || device.groupTag.toLowerCase() !== change.previousGroupTag.toLowerCase()) {
      return device;
    }
    return { ...device, groupTag: change.groupTag };
  });
}
