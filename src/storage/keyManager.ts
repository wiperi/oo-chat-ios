/* eslint-disable no-bitwise */
import 'react-native-get-random-values';
import * as Keychain from 'react-native-keychain';
import nacl from 'tweetnacl';
import type { SignedMessage, StoredIdentity } from '../types';

const IDENTITY_SERVICE = 'connectonion.mobile.identity.ed25519';
const AGENT_TOKEN_SERVICE_PREFIX = 'connectonion.mobile.agent-token.';

interface KeychainIdentity extends StoredIdentity {
  seedHex: string;
  secretKeyHex: string;
}

export interface StoredAgentToken {
  agentAddress: string;
  createdAt: number;
  updatedAt: number;
}

interface KeychainAgentToken extends StoredAgentToken {
  token: string;
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map(byte => byte.toString(16).padStart(2, '0'))
    .join('');
}

function fromHex(hex: string): Uint8Array {
  if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length % 2 !== 0) {
    throw new Error('Invalid hex value.');
  }

  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

function randomSeed(): Uint8Array {
  const bytes = new Uint8Array(32);
  (globalThis as unknown as {
    crypto: { getRandomValues<T extends Uint8Array>(array: T): T };
  }).crypto.getRandomValues(bytes);
  return bytes;
}

function utf8Bytes(value: string): Uint8Array {
  const bytes: number[] = [];
  for (let i = 0; i < value.length; i += 1) {
    let codePoint = value.charCodeAt(i);
    if (codePoint >= 0xd800 && codePoint <= 0xdbff && i + 1 < value.length) {
      const next = value.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (next - 0xdc00);
        i += 1;
      }
    }

    if (codePoint <= 0x7f) {
      bytes.push(codePoint);
    } else if (codePoint <= 0x7ff) {
      bytes.push(0xc0 | (codePoint >> 6), 0x80 | (codePoint & 0x3f));
    } else if (codePoint <= 0xffff) {
      bytes.push(
        0xe0 | (codePoint >> 12),
        0x80 | ((codePoint >> 6) & 0x3f),
        0x80 | (codePoint & 0x3f),
      );
    } else {
      bytes.push(
        0xf0 | (codePoint >> 18),
        0x80 | ((codePoint >> 12) & 0x3f),
        0x80 | ((codePoint >> 6) & 0x3f),
        0x80 | (codePoint & 0x3f),
      );
    }
  }
  return new Uint8Array(bytes);
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value && typeof value === 'object') {
    const input = value as Record<string, unknown>;
    return Object.keys(input).sort().reduce<Record<string, unknown>>((result, key) => {
      result[key] = canonicalize(input[key]);
      return result;
    }, {});
  }
  return value;
}

function buildIdentityFromSeed(seed: Uint8Array, createdAt = Date.now()): KeychainIdentity {
  if (seed.length !== 32) {
    throw new Error('Ed25519 seed must be 32 bytes.');
  }

  const keyPair = nacl.sign.keyPair.fromSeed(seed);
  const publicKeyHex = toHex(keyPair.publicKey);
  return {
    address: `0x${publicKeyHex}`,
    publicKeyHex,
    seedHex: toHex(seed),
    secretKeyHex: toHex(keyPair.secretKey),
    createdAt,
  };
}

function publicIdentity(identity: KeychainIdentity): StoredIdentity {
  return {
    address: identity.address,
    publicKeyHex: identity.publicKeyHex,
    createdAt: identity.createdAt,
  };
}

async function storeRawIdentity(identity: KeychainIdentity): Promise<void> {
  await Keychain.setGenericPassword(identity.address, JSON.stringify(identity), {
    service: IDENTITY_SERVICE,
    accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
  });
}

async function loadRawIdentity(): Promise<KeychainIdentity | null> {
  const credentials = await Keychain.getGenericPassword({ service: IDENTITY_SERVICE });
  if (!credentials) {
    return null;
  }
  const identity = JSON.parse(credentials.password) as KeychainIdentity;
  if (!identity.seedHex && identity.secretKeyHex) {
    const secretKey = fromHex(identity.secretKeyHex);
    if (secretKey.length >= 32) {
      identity.seedHex = toHex(secretKey.slice(0, 32));
    }
  }
  return identity;
}

async function createRawIdentity(): Promise<KeychainIdentity> {
  const identity = buildIdentityFromSeed(randomSeed());
  await storeRawIdentity(identity);
  return identity;
}

async function loadOrCreateRawIdentity(): Promise<KeychainIdentity> {
  const existing = await loadRawIdentity();
  if (existing) {
    return existing;
  }

  return createRawIdentity();
}

function agentTokenService(agentAddress: string): string {
  return `${AGENT_TOKEN_SERVICE_PREFIX}${agentAddress.toLowerCase()}`;
}

export async function loadOrCreateIdentity(): Promise<StoredIdentity> {
  return publicIdentity(await loadOrCreateRawIdentity());
}

export async function exportIdentitySeed(): Promise<string> {
  const identity = await loadOrCreateRawIdentity();
  return identity.seedHex;
}

export async function importIdentitySeed(seedHex: string): Promise<StoredIdentity> {
  const normalized = seedHex.trim().replace(/^0x/i, '');
  const identity = buildIdentityFromSeed(fromHex(normalized));
  await storeRawIdentity(identity);
  return publicIdentity(identity);
}

export async function resetIdentity(): Promise<void> {
  await Keychain.resetGenericPassword({ service: IDENTITY_SERVICE });
}

export async function signPayload(type: string, payload: Record<string, unknown>): Promise<SignedMessage> {
  const identity = await loadOrCreateRawIdentity();
  const canonicalPayload = canonicalize(payload) as Record<string, unknown>;
  const signature = nacl.sign.detached(
    utf8Bytes(JSON.stringify(canonicalPayload)),
    fromHex(identity.secretKeyHex),
  );

  return {
    type,
    payload: canonicalPayload,
    from: identity.address,
    signature: toHex(signature),
    timestamp: canonicalPayload.timestamp,
  };
}

export async function saveAgentToken(agentAddress: string, token: string): Promise<StoredAgentToken> {
  const trimmedToken = token.trim();
  if (!trimmedToken) {
    throw new Error('Token cannot be empty.');
  }

  const existing = await loadAgentTokenMetadata(agentAddress);
  const now = Date.now();
  const entry: KeychainAgentToken = {
    agentAddress,
    token: trimmedToken,
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
  };

  await Keychain.setGenericPassword(agentAddress, JSON.stringify(entry), {
    service: agentTokenService(agentAddress),
    accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
  });

  return {
    agentAddress: entry.agentAddress,
    createdAt: entry.createdAt,
    updatedAt: entry.updatedAt,
  };
}

export async function loadAgentToken(agentAddress: string): Promise<string | null> {
  const credentials = await Keychain.getGenericPassword({
    service: agentTokenService(agentAddress),
  });
  if (!credentials) {
    return null;
  }

  try {
    return (JSON.parse(credentials.password) as KeychainAgentToken).token;
  } catch {
    return credentials.password;
  }
}

export async function loadAgentTokenMetadata(agentAddress: string): Promise<StoredAgentToken | null> {
  const credentials = await Keychain.getGenericPassword({
    service: agentTokenService(agentAddress),
  });
  if (!credentials) {
    return null;
  }

  try {
    const entry = JSON.parse(credentials.password) as KeychainAgentToken;
    return {
      agentAddress: entry.agentAddress,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
    };
  } catch {
    return {
      agentAddress,
      createdAt: 0,
      updatedAt: 0,
    };
  }
}

export async function deleteAgentSecrets(agentAddress: string): Promise<void> {
  await Keychain.resetGenericPassword({
    service: agentTokenService(agentAddress),
  });
}
