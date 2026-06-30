
  jest.mock('../src/storage/keyManager', () => ({
    signPayload: jest.fn(async (type: string, payload: Record<string, unknown>) => ({
      type,
      payload,
      from: '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      signature: 'mock-signature',
      timestamp: payload.timestamp,
    })),
  }));

  import {
    isHostedAgentAddress,
    resolveHostedAgentEndpoint,
    testAgentConnection,
  } from '../src/session/remoteAgentClient';
  import { signPayload } from '../src/storage/keyManager';

  describe('remoteAgentClient', () => {
    const agentAddress =
      '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    beforeEach(() => {
      jest.resetAllMocks();
    });

    test('validates hosted agent address format', () => {
      expect(
        isHostedAgentAddress(
          '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      ).toBe(true);

      expect(isHostedAgentAddress('0xabc')).toBe(false);
      expect(isHostedAgentAddress('not-an-address')).toBe(false);
    });

    test('resolves localhost websocket when /info matches agent address', async () => {
      globalThis.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({address: agentAddress}),
      }) as jest.Mock;

      await expect(resolveHostedAgentEndpoint(agentAddress)).resolves.toBe(
        'ws://localhost:8000/ws',
      );
    });

    test('falls back to relay websocket when local endpoint does not match', async () => {
      globalThis.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({
          address:
            '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        }),
      }) as jest.Mock;

      await expect(resolveHostedAgentEndpoint(agentAddress)).resolves.toBe(
        'wss://oo.openonion.ai/ws/input',
      );
    });

    test('rejects invalid agent address', async () => {
      await expect(resolveHostedAgentEndpoint('bad-address')).rejects.toThrow(
        'Invalid hosted agent address',
      );
    });

    test('test connection sends CONNECT and reports success', async () => {
      globalThis.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({address: agentAddress}),
      }) as jest.Mock;
      const sockets: MockSocket[] = [];
      const WebSocketImpl = makeMockWebSocket(sockets);

      const promise = testAgentConnection(agentAddress, {
        WebSocketImpl,
        timeoutMs: 100,
      });

      await waitForSocket(sockets);
      sockets[0].onopen?.();
      await waitForSentMessage(sockets[0]);
      const sentFrame = JSON.parse(sockets[0].sent[0]);
      expect(signPayload).toHaveBeenCalledWith('CONNECT', {
        timestamp: expect.any(Number),
        to: agentAddress,
      });
      expect(sentFrame).toEqual({
        type: 'CONNECT',
        payload: {
          timestamp: expect.any(Number),
          to: agentAddress,
        },
        from: '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        signature: 'mock-signature',
        timestamp: expect.any(Number),
        to: agentAddress,
      });
      sockets[0].onmessage?.({data: JSON.stringify({type: 'CONNECTED'})});

      await expect(promise).resolves.toEqual({
        ok: true,
        endpoint: 'ws://localhost:8000/ws',
        message: 'Connected to ws://localhost:8000/ws.',
      });
    });

    test('test connection reports backend failure reason', async () => {
      globalThis.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({address: agentAddress}),
      }) as jest.Mock;
      const sockets: MockSocket[] = [];
      const WebSocketImpl = makeMockWebSocket(sockets);

      const promise = testAgentConnection(agentAddress, {
        WebSocketImpl,
        timeoutMs: 100,
      });

      await waitForSocket(sockets);
      sockets[0].onopen?.();
      sockets[0].onmessage?.({data: JSON.stringify({type: 'ERROR', message: 'token expired'})});

      await expect(promise).resolves.toEqual({
        ok: false,
        message: 'token expired',
      });
    });
  });

class MockSocket {
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  sent: string[] = [];

  constructor(readonly url: string) {}

  send(data: string) {
    this.sent.push(data);
  }

  close() {}
}

function makeMockWebSocket(sockets: MockSocket[]) {
  return class extends MockSocket {
    constructor(url: string) {
      super(url);
      sockets.push(this);
    }
  };
}

// testAgentConnection resolves the endpoint (several awaited fetch ticks) before
// it constructs the WebSocket, so we poll the microtask queue until the mock
// socket exists rather than guessing a fixed number of ticks.
async function waitForSocket(sockets: MockSocket[], index = 0) {
  for (let i = 0; i < 100; i++) {
    if (sockets[index]) {
      return;
    }
    await Promise.resolve();
  }
  throw new Error('Expected a WebSocket to be constructed');
}

async function waitForSentMessage(socket: MockSocket, index = 0) {
  for (let i = 0; i < 100; i++) {
    if (socket.sent[index]) {
      return;
    }
    await Promise.resolve();
  }
  throw new Error('Expected a WebSocket message to be sent');
}
