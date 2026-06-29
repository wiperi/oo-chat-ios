export function shortAddress(address?: string): string {
  if (!address) {
    return 'No identity';
  }
  if (address.length <= 14) {
    return address;
  }
  return `${address.slice(0, 8)}...${address.slice(-6)}`;
}

export function formatTime(ms: number): string {
  return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

export function compactJson(value: unknown): string {
  if (!value) {
    return 'None';
  }
  return JSON.stringify(value, null, 2);
}
