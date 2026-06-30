export type PreviewConnectionState = 'disconnected' | 'connected';

export interface PreviewChatItem {
  id: string;
  type: 'user' | 'agent' | 'system';
  content: string;
  timestamp: number;
}

export interface PreviewConversation {
  id: string;
  title: string;
  agentAddress: string;
  updatedAt: number;
  ui: PreviewChatItem[];
  serverSession?: Record<string, unknown>;
}
