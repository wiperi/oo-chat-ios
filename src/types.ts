export type ApprovalMode = 'safe' | 'plan' | 'accept_edits' | 'ulw';

export type ConnectionState = 'disconnected' | 'connected' | 'reconnecting';

export type AgentStatus = 'idle' | 'working' | 'waiting';

export interface FileAttachment {
  id: string;
  kind: 'image' | 'file';
  name: string;
  type: string;
  size: number;
  uri: string;
  dataUrl?: string;
}

export interface AskUserField {
  name: string;
  label: string;
  type?: 'text' | 'password';
  placeholder?: string;
  required?: boolean;
}

export type ChatItem =
  | { id: string; type: 'user'; content: string; images?: string[]; files?: FileAttachment[] }
  | { id: string; type: 'agent'; content: string; images?: string[] }
  | { id: string; type: 'error'; message: string; code?: string }
  | { id: string; type: 'thinking'; status: 'running' | 'done' | 'error'; model?: string; duration_ms?: number; content?: string; kind?: string; context_percent?: number }
  | { id: string; type: 'tool_call'; name: string; args?: Record<string, unknown>; status: 'running' | 'done' | 'error'; result?: string; timing_ms?: number }
  | { id: string; type: 'ask_user'; text: string; options: string[]; multi_select: boolean; input_type?: string; fields?: AskUserField[]; answered?: boolean; answer?: string | string[] }
  | { id: string; type: 'approval_needed'; tool: string; arguments: Record<string, unknown>; description?: string; batch_remaining?: Array<{ tool: string; arguments: string }>; resolved?: boolean }
  | { id: string; type: 'onboard_required'; methods: string[]; paymentAmount?: number; resolved?: boolean }
  | { id: string; type: 'onboard_success'; level: string; message: string }
  | { id: string; type: 'intent'; status: 'analyzing' | 'understood'; ack?: string; is_build?: boolean }
  | { id: string; type: 'eval'; status: 'evaluating' | 'done'; passed?: boolean; summary?: string; expected?: string; eval_path?: string }
  | { id: string; type: 'compact'; status: 'compacting' | 'done' | 'error'; context_before?: number; context_after?: number; context_percent?: number; message?: string; error?: string }
  | { id: string; type: 'tool_blocked'; tool: string; reason: string; message: string; command?: string }
  | { id: string; type: 'ulw_turns_reached'; turns_used: number; max_turns: number; resolved?: boolean }
  | { id: string; type: 'plan_review'; plan_content: string; resolved?: boolean; response?: string }
  | { id: string; type: 'files_received'; files: Array<{ name: string; path: string }> };

export interface Conversation {
  id: string;
  title: string;
  agentAddress: string;
  createdAt: number;
  updatedAt: number;
  mode: ApprovalMode;
  ulwTurns: number | null;
  ulwTurnsUsed: number | null;
  serverSession?: Record<string, unknown>;
  ui: ChatItem[];
}

export interface StoredIdentity {
  address: string;
  publicKeyHex: string;
  createdAt: number;
}

export interface SignedMessage {
  type: string;
  payload: Record<string, unknown>;
  from: string;
  signature: string;
  timestamp?: unknown;
}

export interface PendingAskUser {
  id: string;
  question: string;
  options: string[];
  multi_select: boolean;
  input_type?: string;
  fields?: AskUserField[];
}

export interface PendingApproval {
  id: string;
  tool: string;
  arguments: Record<string, unknown>;
  description?: string;
  batch_remaining?: Array<{ tool: string; arguments: string }>;
}

export interface PendingOnboard {
  id: string;
  methods: string[];
  paymentAmount?: number;
}

export interface PendingPlanReview {
  id: string;
  plan_content: string;
}

export interface PendingUlwTurnsReached {
  id: string;
  turns_used: number;
  max_turns: number;
}

export type ActiveGate =
  | { kind: 'ask_user'; data: PendingAskUser }
  | { kind: 'approval'; data: PendingApproval }
  | { kind: 'onboard'; data: PendingOnboard }
  | { kind: 'plan_review'; data: PendingPlanReview }
  | { kind: 'ulw'; data: PendingUlwTurnsReached }
  | null;
