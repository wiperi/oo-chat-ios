import { signPayload } from '../storage/keyManager';
import type { ChatItem, Conversation, FileAttachment, SignedMessage } from '../types';

const DEFAULT_RELAY_URL = 'wss://oo.openonion.ai';
const LOCAL_DEV_ENDPOINTS = ['http://localhost:8000', 'http://127.0.0.1:8000'];

type ConnectionKind = 'direct' | 'relay';

interface AgentInfo {
  address?: string;
  name?: string;
  endpoints?: string[];
}

interface ResolvedEndpoint {
  wsUrl: string;
  kind: ConnectionKind;
  label: string;
}

interface ProtocolFrame extends Record<string, unknown> {
  type: string;
}

export interface HostedAgentResult {
  items: ChatItem[];
  serverSession?: Record<string, unknown>;
  sessionId?: string;
  done: boolean;
  endpoint: string;
}

export interface HostedAgentCallbacks {
  onConnectionState?: (state: 'disconnected' | 'connected' | 'reconnecting') => void;
  onOutbound?: (message: SignedMessage | ProtocolFrame) => void;
  onStreamItems?: (items: ChatItem[]) => void;
}

function makeId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function normalizeRelayUrrl(relayUrl: string): string {
  let normalized = relayUrl.replace(/\/$/, '');
  if (normalized.endsWith('/ws/announce')) {
    normalized = normalized.slice(0, -'/ws/announce'.length);
  } else if (normalized.endsWith('/ws')) {
    normalized = normalized.slice(0, -'/ws'.length);
  }
  return normalized;
}

function httpToWs(httpUrl: string): string {
  const baseUrl = httpUrl.replace(/^https?:\/\//, '');
  const protocol = httpUrl.startsWith('https') ? 'wss' : 'ws';
  return `${protocol}://${baseUrl}/ws`;
}

function sortByProxemity(endpoints: string[]): string[] {
  return [...endpoints].sort((a, b) => {
    const priority = (url: string) => {
      if (url.includes('localhost') || url.includes('127.0.0.1')) {
        return 0;
      }
      if (url.includes('192.168.') || url.includes('10.') || url.includes('172.16.')) {
        return 1;
      }
      return 2;
    };
    return priority(a) - priority(b);
  });
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs);
  });

  try {
    return await Promise.race([promise, timeout]);
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

async function fetchJson<T>(url: string, timeoutMs: number): Promise<T | null> {
  try {
    const response = await withTimeout(fetch(url), timeoutMs, url);
    if (!response.ok) {
      return null;
    }
    return await response.json() as T;
  } catch {
    return null;
  }
}

async function probeHttpEndpoint(httpUrl: string, agentAddress: string, timeoutMs: number): Promise<ResolvedEndpoint | null> {
  const info = await fetchJson<AgentInfo>(`${httpUrl}/info`, timeoutMs);
  if (info?.address !== agentAddress) {
    return null;
  }

  return {
    wsUrl: httpToWs(httpUrl),
    kind: 'direct',
    label: info.name ? `${info.name} at ${httpUrl}` : httpUrl,
  };
}

async function resolveHostedAgentEndpoint(agentAddress: string, relayUrl = DEFAULT_RELAY_URL): Promise<ResolvedEndpoint> {
  for (const httpUrl of LOCAL_DEV_ENDPOINTS) {
    const localEndpoint = await probeHttpEndpoint(httpUrl, agentAddress, 1200);
    if (localEndpoint) {
      return localEndpoint;
    }
  }

  const normallizedRelay = normalizeRelayUrrl(relayUrl);
  const httpsRelay = normallizedRelay.replace(/^wss?:\/\//, 'https://');
  const relayData = await fetchJson<AgentInfo>(`${httpsRelay}/api/relay/agents/${agentAddress}`, 3000);
  const httpendpoints = sortByProxemity(relayData?.endpoints ?? []).filter(endpoint => endpoint.startsWith('http'));

  for (const httpUrl of httpendpoints) {
    const directEndpoint = await probeHttpEndpoint(httpUrl, agentAddress, 2500);
    if (directEndpoint) {
      return directEndpoint;
    }
  }

  return {
    wsUrl: `${normallizedRelay}/ws/input`,
    kind: 'relay',
    label: normallizedRelay,
  };
}

async function buildConnectFrame(agentAddress: string, conversation: Conversation, endpoint: ResolvedEndpoint): Promise<ProtocolFrame> {
  const timestamp = Math.floor(Date.now() / 1000);
  const signed = await signPayload('CONNECT', { timestamp, to: agentAddress });
  const frame: ProtocolFrame = {
    ...signed,
    type: 'CONNECT',
    timestamp,
    session_id: conversation.id,
  };

  if (conversation.serverSession) {
    frame.session = conversation.serverSession;
  }
  if (endpoint.kind === 'relay') {
    frame.to = agentAddress;
  }

  return frame;
}

function attachmentsForInput(files: FileAttachment[]) {
  const images = files
    .filter(file => file.kind === 'image')
    .map(file => file.dataUrl)
    .filter((value): value is string => Boolean(value));
  const documents = files
    .filter(file => file.kind === 'file')
    .map(file => ({
      name: file.name,
      type: file.type,
      size: file.size,
      uri: file.uri,
      data: file.dataUrl,
    }));

  return {
    ...(images.length > 0 ? { images } : {}),
    ...(documents.length > 0 ? { files: documents } : {}),
  };
}

async function buildInputFrame(
  agentAddress: string,
  prompt: string,
  endpoint: ResolvedEndpoint,
  files: FileAttachment[],
): Promise<ProtocolFrame> {
  const timestamp = Math.floor(Date.now() / 1000);
  const inputId = makeId('input');
  const payload: Record<string, unknown> = { prompt, timestamp };
  if (endpoint.kind === 'relay') {
    payload.to = agentAddress;
  }

  const signed = await signPayload('INPUT', payload);
  const frame: ProtocolFrame = {
    ...signed,
    ...attachmentsForInput(files),
    type: 'INPUT',
    input_id: inputId,
    prompt,
    timestamp,
  };

  if (endpoint.kind === 'relay') {
    frame.to = agentAddress;
  }

  return frame;
}

function messageText(event: Record<string, unknown>): string {
  const message = event.message ?? event.error ?? event.text ?? event.result ?? event.content;
  return typeof message === 'string' ? message : JSON.stringify(message ?? event);
}

function mapStreamEvent(event: Record<string, unknown>): ChatItem[] {
  const type = event.type;
  if (type === 'thinking') {
    return [{
      id: String(event.id ?? makeId('thinking')),
      type: 'thinking',
      status: 'done',
      model: typeof event.model === 'string' ? event.model : undefined,
      content: typeof event.content === 'string' ? event.content : undefined,
      kind: typeof event.kind === 'string' ? event.kind : undefined,
    }];
  }

  if (type === 'assistant' || type === 'agent') {
    return [{ id: String(event.id ?? makeId('agent')), type: 'agent', content: messageText(event) }];
  }

  if (type === 'agent_image' && typeof event.image === 'string') {
    return [{ id: String(event.id ?? makeId('agent')), type: 'agent', content: 'Image received.', images: [event.image] }];
  }

  if (type === 'tool_call') {
    return [{
      id: String(event.id ?? makeId('tool')),
      type: 'tool_call',
      name: typeof event.name === 'string' ? event.name : 'tool',
      args: typeof event.args === 'object' && event.args !== null ? event.args as Record<string, unknown> : undefined,
      status: 'running',
    }];
  }

  if (type === 'tool_result') {
    return [{
      id: String(event.id ?? makeId('tool')),
      type: 'tool_call',
      name: typeof event.name === 'string' ? event.name : 'tool_result',
      status: event.status === 'error' ? 'error' : 'done',
      result: messageText(event),
    }];
  }

  if (type === 'ask_user') {
    return [{
      id: String(event.id ?? makeId('ask')),
      type: 'ask_user',
      text: typeof event.text === 'string' ? event.text : 'The agent needs your input.',
      options: Array.isArray(event.options) ? event.options.map(String) : [],
      multi_select: Boolean(event.multi_select),
      input_type: typeof event.input_type === 'string' ? event.input_type : undefined,
    }];
  }

  if (type === 'approval_needed') {
    return [{
      id: String(event.id ?? makeId('approval')),
      type: 'approval_needed',
      tool: typeof event.tool === 'string' ? event.tool : 'tool',
      arguments: typeof event.arguments === 'object' && event.arguments !== null ? event.arguments as Record<string, unknown> : {},
      description: typeof event.description === 'string' ? event.description : undefined,
      batch_remaining: Array.isArray(event.batch_remaining)
        ? event.batch_remaining.map(item => {
            const row = item as Record<string, unknown>;
            return { tool: String(row.tool ?? 'tool'), arguments: String(row.arguments ?? '') };
          })
        : undefined,
    }];
  }

  if (type === 'ONBOARD_REQUIRED') {
    return [{
      id: String(event.id ?? makeId('onboard')),
      type: 'onboard_required',
      methods: Array.isArray(event.methods) ? event.methods.map(String) : [],
      paymentAmount: typeof event.payment_amount === 'number' ? event.payment_amount : undefined,
    }];
  }

  if (type === 'ONBOARD_SUCCESS') {
    return [{
      id: String(event.id ?? makeId('onboard')),
      type: 'onboard_success',
      level: typeof event.level === 'string' ? event.level : 'contact',
      message: messageText(event),
    }];
  }

  if (type === 'plan_review') {
    return [{
      id: String(event.id ?? makeId('plan')),
      type: 'plan_review',
      plan_content: typeof event.plan_content === 'string' ? event.plan_content : messageText(event),
    }];
  }

  if (type === 'ulw_turns_reached') {
    return [{
      id: String(event.id ?? makeId('ulw')),
      type: 'ulw_turns_reached',
      turns_used: Number(event.turns_used ?? 0),
      max_turns: Number(event.max_turns ?? 0),
    }];
  }

  if (type === 'ERROR') {
    return [{ id: String(event.id ?? makeId('error')), type: 'error', message: messageText(event) }];
  }

  return [];
}

function parseFrame(raw: unknown): Record<string, unknown> | null {
  if (typeof raw !== 'string') {
    return null;
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed as Record<string, unknown> : null;
  } catch {
    return { type: 'ERROR', message: `Invalid JSON from agent: ${raw.slice(0, 120)}` };
  }
}

export async function connectHostedAgent(
  agentAddress: string,
  conversation: Conversation,
  callbacks: HostedAgentCallbacks = {},
): Promise<HostedAgentResult> {
  const endpoint = await resolveHostedAgentEndpoint(agentAddress);
  callbacks.onConnectionState?.('reconnecting');

  return new Promise((resolve, reject) => {
    let settled = false;
    const timeout = setTimeout(() => {
      fail(new Error(`Connection timed out while opening ${endpoint.label}`));
    }, 30000);

    const ws = new WebSocket(endpoint.wsUrl);

    function finish(result: HostedAgentResult) {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      callbacks.onConnectionState?.('connected');
      ws.close();
      resolve(result);
    }

    function fail(error: Error) {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      callbacks.onConnectionState?.('disconnected');
      ws.close();
      reject(error);
    }

    ws.onopen = () => {
      buildConnectFrame(agentAddress, conversation, endpoint)
        .then(frame => {
          callbacks.onOutbound?.(frame);
          ws.send(JSON.stringify(frame));
        })
        .catch(err => fail(err instanceof Error ? err : new Error(String(err))));
    };

    ws.onmessage = event => {
      const frame = parseFrame(event.data);
      if (!frame) {
        return;
      }

      if (frame.type === 'PING') {
        ws.send(JSON.stringify({ type: 'PONG' }));
        return;
      }

      if (frame.type === 'CONNECTED') {
        finish({
          items: [],
          done: true,
          endpoint: endpoint.label,
          sessionId: typeof frame.session_id === 'string' ? frame.session_id : conversation.id,
          serverSession: typeof frame.session === 'object' && frame.session !== null ? frame.session as Record<string, unknown> : undefined,
        });
        return;
      }

      if (frame.type === 'ERROR') {
        fail(new Error(messageText(frame)));
      }
    };

    ws.onerror = () => fail(new Error(`Could not connect to ${endpoint.label}`));
    ws.onclose = () => {
      if (!settled) {
        fail(new Error(`Connection closed before ${endpoint.label} accepted the session`));
      }
    };
  });
}

export async function sendPromptToHostedAgent(
  agentAddress: string,
  conversation: Conversation,
  prompt: string,
  files: FileAttachment[],
  callbacks: HostedAgentCallbacks = {},
): Promise<HostedAgentResult> {
  const endpoint = await resolveHostedAgentEndpoint(agentAddress);
  callbacks.onConnectionState?.('reconnecting');

  return new Promise((resolve, reject) => {
    let settled = false;
    let inputSent = false;
    let sessionId = conversation.id;
    let serverSession = conversation.serverSession;
    const streamedItems: ChatItem[] = [];
    const timeout = setTimeout(() => {
      fail(new Error(`Agent reply timed out via ${endpoint.label}`));
    }, 120000);

    const ws = new WebSocket(endpoint.wsUrl);

    function finish(result: HostedAgentResult) {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      callbacks.onConnectionState?.('connected');
      ws.close();
      resolve(result);
    }

    function fail(error: Error) {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      callbacks.onConnectionState?.('disconnected');
      ws.close();
      reject(error);
    }

    function sendInput() {
      if (inputSent) {
        return;
      }
      inputSent = true;
      buildInputFrame(agentAddress, prompt, endpoint, files)
        .then(frame => {
          callbacks.onOutbound?.(frame);
          ws.send(JSON.stringify(frame));
        })
        .catch(err => fail(err instanceof Error ? err : new Error(String(err))));
    }

    ws.onopen = () => {
      buildConnectFrame(agentAddress, conversation, endpoint)
        .then(frame => {
          callbacks.onOutbound?.(frame);
          ws.send(JSON.stringify(frame));
        })
        .catch(err => fail(err instanceof Error ? err : new Error(String(err))));
    };

    ws.onmessage = event => {
      const frame = parseFrame(event.data);
      if (!frame) {
        return;
      }

      if (frame.type === 'PING') {
        ws.send(JSON.stringify({ type: 'PONG' }));
        return;
      }

      if (frame.type === 'CONNECTED') {
        callbacks.onConnectionState?.('connected');
        sessionId = typeof frame.session_id === 'string' ? frame.session_id : conversation.id;
        if (typeof frame.session === 'object' && frame.session !== null) {
          serverSession = frame.session as Record<string, unknown>;
        }
        sendInput();
        return;
      }

      if (frame.type === 'OUTPUT') {
        const result = typeof frame.result === 'string' ? frame.result : messageText(frame);
        const duration = typeof frame.duration_ms === 'number' ? frame.duration_ms : undefined;
        const finalItems: ChatItem[] = [
          ...(duration ? [{
            id: makeId('thinking'),
            type: 'thinking' as const,
            status: 'done' as const,
            duration_ms: duration,
            content: 'Agent response received.',
          }] : []),
          { id: makeId('agent'), type: 'agent', content: result },
        ];
        finish({
          items: finalItems,
          done: true,
          endpoint: endpoint.label,
          sessionId,
          serverSession: typeof frame.session === 'object' && frame.session !== null ? frame.session as Record<string, unknown> : serverSession,
        });
        return;
      }

      if (frame.type === 'ERROR') {
        fail(new Error(messageText(frame)));
        return;
      }

      const items = mapStreamEvent(frame);
      if (items.length > 0) {
        streamedItems.push(...items);
        callbacks.onStreamItems?.(items);
      }

      if (frame.type === 'ask_user' || frame.type === 'approval_needed' || frame.type === 'ONBOARD_REQUIRED' || frame.type === 'plan_review' || frame.type === 'ulw_turns_reached') {
        finish({
          items: [],
          done: false,
          endpoint: endpoint.label,
          sessionId,
          serverSession,
        });
      }
    };

    ws.onerror = () => fail(new Error(`WebSocket error while talking to ${endpoint.label}`));
    ws.onclose = () => {
      if (!settled) {
        fail(new Error('Connection closed before the agent replied'));
      }
    };
  });
}
