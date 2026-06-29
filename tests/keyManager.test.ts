const mockKeychainStore = new Map<string, { username: string; password: string }>();

jest.mock('react-native-get-random-values', () => undefined);

jest.mock('react-native-keychain', () => ({
  ACCESSIBLE: {
    AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY: 'AccessibleAfterFirstUnlockThisDeviceOnly',
  },
  getGenericPassword: jest.fn(async ({ service }: { service: string }) => mockKeychainStore.get(service) ?? false),
  setGenericPassword: jest.fn(async (username: string, password: string, { service }: { service: string }) => {
    mockKeychainStore.set(service, { username, password });
    return true;
  }),
  resetGenericPassword: jest.fn(async ({ service }: { service: string }) => {
    mockKeychainStore.delete(service);
    return true;
  }),
}));

import {
  deleteAgentSecrets,
  exportIdentitySeed,
  importIdentitySeed,
  loadAgentToken,
  loadAgentTokenMetadata,
  loadOrCreateIdentity,
  resetIdentity,
  saveAgentToken,
  signPayload,
} from '../src/storage/keyManager';

const agentAddress = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

describe('keyManager', () => {
  beforeEach(() => {
    mockKeychainStore.clear();
    jest.clearAllMocks();
    Object.defineProperty(globalThis, 'crypto', {
      configurable: true,
      value: {
        getRandomValues: (array: Uint8Array) => {
          array.fill(7);
          return array;
        },
      },
    });
  });

  test('creates and reloads a public identity backed by Keychain', async () => {
    const first = await loadOrCreateIdentity();
    const second = await loadOrCreateIdentity();

    expect(first).toEqual(second);
    expect(first.address).toMatch(/^0x[0-9a-f]{64}$/);
    expect(first.publicKeyHex).toHaveLength(64);
    expect(JSON.stringify(first)).not.toContain('secretKeyHex');
    expect(JSON.stringify(first)).not.toContain('seedHex');
  });

  test('signs canonical payloads without exposing private material', async () => {
    const signed = await signPayload('INPUT', {
      z: 1,
      a: { c: true, b: 'two' },
      timestamp: 123,
    });

    expect(signed).toEqual(expect.objectContaining({
      type: 'INPUT',
      from: expect.stringMatching(/^0x[0-9a-f]{64}$/),
      signature: expect.stringMatching(/^[0-9a-f]{128}$/),
      timestamp: 123,
    }));
    expect(Object.keys(signed.payload)).toEqual(['a', 'timestamp', 'z']);
    expect(Object.keys(signed.payload.a as Record<string, unknown>)).toEqual(['b', 'c']);
    expect(JSON.stringify(signed)).not.toContain('secretKeyHex');
    expect(JSON.stringify(signed)).not.toContain('seedHex');
  });

  test('exports, imports, and resets the identity seed', async () => {
    const original = await loadOrCreateIdentity();
    const seed = await exportIdentitySeed();

    await resetIdentity();
    expect(await loadOrCreateIdentity()).toEqual(expect.objectContaining({
      address: original.address,
      publicKeyHex: original.publicKeyHex,
    }));

    const imported = await importIdentitySeed(seed);
    expect(imported).toEqual(expect.objectContaining({
      address: original.address,
      publicKeyHex: original.publicKeyHex,
    }));
  });

  test('stores, loads, and deletes agent tokens in Keychain', async () => {
    const metadata = await saveAgentToken(agentAddress, ' token-123 ');

    expect(metadata).toEqual(expect.objectContaining({
      agentAddress,
      createdAt: expect.any(Number),
      updatedAt: expect.any(Number),
    }));
    expect(JSON.stringify(metadata)).not.toContain('token-123');
    expect(await loadAgentToken(agentAddress)).toBe('token-123');
    expect(await loadAgentTokenMetadata(agentAddress)).toEqual(metadata);

    await deleteAgentSecrets(agentAddress);

    expect(await loadAgentToken(agentAddress)).toBeNull();
    expect(await loadAgentTokenMetadata(agentAddress)).toBeNull();
  });
});
