
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
    sendPromptToHostedAgent,
    testAgentConnection,
  } from '../src/session/remoteAgentClient';
  import { signPayload } from '../src/storage/keyManager';

  describe('remoteAgentClient', () => {
    const agentAddress =
      '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    beforeEach(() => {
      jest.clearAllMocks();
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

    test('keeps hosted agent tool events before final output', async () => {
      globalThis.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({address: agentAddress}),
      }) as jest.Mock;
      const sockets: MockSocket[] = [];
      const WebSocketImpl = makeMockWebSocket(sockets);
      const previousWebSocket = globalThis.WebSocket;
      Object.defineProperty(globalThis, 'WebSocket', {
        configurable: true,
        value: WebSocketImpl,
      });

      try {
        const promise = sendPromptToHostedAgent(
          agentAddress,
          {
            id: 'conversation-1',
            title: 'Test conversation',
            agentAddress,
            createdAt: 1,
            updatedAt: 1,
            mode: 'safe',
            ulwTurns: null,
            ulwTurnsUsed: null,
            ui: [],
          },
          'hello',
          [],
        );

        await waitForSocket(sockets);
        sockets[0].onopen?.();
        await waitForSentMessage(sockets[0]);
        sockets[0].onmessage?.({data: JSON.stringify({type: 'CONNECTED', session_id: 'server-session-1'})});
        await waitForSentMessage(sockets[0], 1);

        sockets[0].onmessage?.({data: JSON.stringify({type: 'llm_call', id: 'llm-1', model: 'gemini-2.5-pro'})});
        sockets[0].onmessage?.({data: JSON.stringify({type: 'tool_call', tool_id: 'tool-1', name: 'search'})});
        sockets[0].onmessage?.({data: JSON.stringify({type: 'tool_result', tool_id: 'tool-1', name: 'search', result: 'found it'})});
        sockets[0].onmessage?.({data: JSON.stringify({type: 'llm_result', id: 'llm-1', model: 'gemini-2.5-pro', duration_ms: 1200})});

        sockets[0].onmessage?.({
          data: JSON.stringify({
            type: 'OUTPUT',
            result: 'Hello world',
            session: {turn: 1},
          }),
        });

        await expect(promise).resolves.toEqual({
          items: [
            expect.objectContaining({
              id: 'tool-1',
              type: 'tool_call',
              name: 'search',
              status: 'done',
              result: 'found it',
            }),
            expect.objectContaining({type: 'agent', content: 'Hello world'}),
          ],
          done: true,
          endpoint: 'http://localhost:8000',
          sessionId: 'server-session-1',
          serverSession: {turn: 1},
        });
      } finally {
        Object.defineProperty(globalThis, 'WebSocket', {
          configurable: true,
          value: previousWebSocket,
        });
      }
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
