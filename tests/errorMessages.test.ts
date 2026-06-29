import {
  actionLabel,
  classifyConnectionError,
  invalidAddressError,
  toUserFacingError,
  type ConnectionErrorKind,
} from '../src/utils/errorMessages';

const NETWORK_MESSAGES = [
  'Could not connect to ws://localhost:8000/ws.',
  'WebSocket error while talking to wss://oo.openonion.ai',
  'Connection closed before the agent replied',
  'Network request failed',
];

const TIMEOUT_MESSAGES = [
  'http://localhost:8000/info timed out after 1200ms',
  'Connection timed out while opening wss://oo.openonion.ai.',
  'Agent reply timed out via wss://oo.openonion.ai',
];

const INVALID_ENDPOINT_MESSAGES = [
  'Invalid hosted agent address',
  'Invalid hosted agent address.',
  'Connection closed before ws://localhost:8000/ws accepted the session.',
  'Enter a hosted agent address in 0x-prefixed Ed25519 format.',
];

describe('classifyConnectionError', () => {
  test('classifies network-loss failures', () => {
    for (const message of NETWORK_MESSAGES) {
      expect(classifyConnectionError(message)).toBe('network');
      expect(classifyConnectionError(new Error(message))).toBe('network');
    }
  });

  test('classifies timeout failures', () => {
    for (const message of TIMEOUT_MESSAGES) {
      expect(classifyConnectionError(message)).toBe('timeout');
      expect(classifyConnectionError(new Error(message))).toBe('timeout');
    }
  });

  test('classifies invalid-endpoint failures', () => {
    for (const message of INVALID_ENDPOINT_MESSAGES) {
      expect(classifyConnectionError(message)).toBe('invalid-endpoint');
    }
  });

  test('reads the message out of a ConnectionTestResult-shaped object', () => {
    expect(
      classifyConnectionError({ ok: false, message: 'Could not connect to ws://x/ws.' }),
    ).toBe('network');
  });

  test('falls back to unknown for empty or unrecognised input', () => {
    expect(classifyConnectionError('')).toBe('unknown');
    expect(classifyConnectionError(null)).toBe('unknown');
    expect(classifyConnectionError(undefined)).toBe('unknown');
    expect(classifyConnectionError({})).toBe('unknown');
    expect(classifyConnectionError('token expired')).toBe('unknown');
  });

  test('prefers timeout and invalid-endpoint over the broader network match', () => {
    // handshake rejection
    expect(
      classifyConnectionError('Connection closed before wss://x accepted the session.'),
    ).toBe('invalid-endpoint');
    expect(
      classifyConnectionError('Connection timed out while opening wss://x.'),
    ).toBe('timeout');
  });
});

describe('toUserFacingError', () => {
  test('each AC category produces a clear message and a next action', () => {
    const cases: Array<[string, ConnectionErrorKind]> = [
      [NETWORK_MESSAGES[0], 'network'],
      [TIMEOUT_MESSAGES[0], 'timeout'],
      [INVALID_ENDPOINT_MESSAGES[0], 'invalid-endpoint'],
    ];

    for (const [message, kind] of cases) {
      const result = toUserFacingError(message);
      expect(result.kind).toBe(kind);
      expect(result.title.length).toBeGreaterThan(0);
      expect(result.message.length).toBeGreaterThan(0);
      expect(result.actions.length).toBeGreaterThan(0);
    }
  });

  test('every error state offers retry, edit-connection or dismiss', () => {
    const messages = [
      ...NETWORK_MESSAGES,
      ...TIMEOUT_MESSAGES,
      ...INVALID_ENDPOINT_MESSAGES,
      'totally unexpected failure',
    ];

    for (const message of messages) {
      const { actions } = toUserFacingError(message);
      expect(actions.length).toBeGreaterThan(0);
      expect(actions).toContain('dismiss');
      for (const action of actions) {
        expect(['retry', 'edit-connection', 'dismiss']).toContain(action);
      }
    }
  });

  test('never leaks raw exception text, URLs or HTTP status codes', () => {
    const leaky = [
      ...NETWORK_MESSAGES,
      ...TIMEOUT_MESSAGES,
      'HTTP 503 Service Unavailable at https://oo.openonion.ai/api',
      'TypeError: Cannot read properties of undefined (reading send)',
      'Error: connect ECONNREFUSED 127.0.0.1:8000',
    ];

    for (const message of leaky) {
      const result = toUserFacingError(message);
      // no URLs, no "ws"/"http" protocol leakage, no millisecond counts,
      // no 3-digit status codes, no stack/Error noise.
      expect(result.message).not.toMatch(/https?:\/\//i);
      expect(result.message).not.toMatch(/wss?:\/\//i);
      expect(result.message).not.toMatch(/\d{3,}/);
      expect(result.message.toLowerCase()).not.toContain('websocket');
      expect(result.message.toLowerCase()).not.toContain('exception');
      expect(result.message).not.toContain('Error:');
      expect(result.message).not.toContain('TypeError');
    }
  });
});

describe('invalidAddressError', () => {
  test('keeps the specific format guidance and offers an action', () => {
    const error = invalidAddressError();
    expect(error.kind).toBe('invalid-endpoint');
    expect(error.message).toContain('0x-prefixed');
    expect(error.actions).toContain('edit-connection');
    expect(error.actions).toContain('dismiss');
  });
});

describe('actionLabel', () => {
  test('maps every action to a human label', () => {
    expect(actionLabel('retry')).toBe('Retry');
    expect(actionLabel('edit-connection')).toBe('Edit connection');
    expect(actionLabel('dismiss')).toBe('Dismiss');
  });
});
