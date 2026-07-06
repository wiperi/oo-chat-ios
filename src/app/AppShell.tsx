import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { AppState, Keyboard, KeyboardAvoidingView, Platform, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { TabBar } from '../components/layout/TabBar';
import { AddAgentScreen } from '../screens/AddAgentScreen';
import { AgentsScreen } from '../screens/AgentsScreen';
import { ChatScreen } from '../screens/ChatScreen';
import { HistoryScreen } from '../screens/HistoryScreen';
import { SettingsScreen } from '../screens/SettingsScreen';
import {
  exportIdentitySeed,
  importIdentitySeed,
  loadAgentTokenMetadata,
  loadOrCreateIdentity,
  resetIdentity,
  saveAgentToken,
  type StoredAgentToken,
} from '../storage/keyManager';
import {
  deleteConversation,
  listConversations,
  loadActiveConversationId,
  saveActiveConversationId,
  saveConversation,
} from '../storage/sessionRepository';
import { testAgentConnectionForm } from '../agent/agentConnectionConfig';
import { sendPromptToHostedAgent } from '../session/remoteAgentClient';
import { styles } from '../styles/appStyles';
import type { ChatItem, Conversation, StoredIdentity } from '../types';
import { shortAddress } from '../utils/format';
import {
  invalidAddressError,
  toUserFacingError,
  type ErrorAction,
  type UserFacingError,
} from '../utils/errorMessages';
import type { PreviewChatItem, PreviewConnectionState, PreviewConversation } from './previewTypes';
import type { AppTab } from './tabs';

function isHostedAgentAddress(address: string): boolean {
  return /^0x[0-9a-fA-F]{64}$/.test(address);
}

function makeId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function titleFromPrompt(prompt: string): string {
  const compact = prompt.trim().replace(/\s+/g, ' ');
  if (!compact) {
    return 'New conversation';
  }
  return compact.length > 34 ? `${compact.slice(0, 31)}...` : compact;
}

function starterConversation(agentAddress: string): PreviewConversation {
  return {
    id: makeId('conversation'),
    title: shortAddress(agentAddress),
    agentAddress,
    updatedAt: Date.now(),
    ui: [],
  };
}

// Bridge between the UI-facing PreviewConversation and the persisted Conversation
// shape that sessionRepository / the hosted-agent client speak. Kept lossless for the
// three preview item kinds (user / agent / system) so a saved conversation round-trips.
function toHostedConversation(conversation: PreviewConversation): Conversation {
  return {
    id: conversation.id,
    title: conversation.title,
    agentAddress: conversation.agentAddress,
    createdAt: conversation.updatedAt,
    updatedAt: conversation.updatedAt,
    mode: 'safe',
    ulwTurns: null,
    ulwTurnsUsed: null,
    serverSession: conversation.serverSession,
    ui: conversation.ui.map(item => ({
      id: item.id,
      type: item.type === 'system' ? 'error' : item.type,
      content: item.content,
      message: item.content,
    })) as ChatItem[],
  };
}

function previewItemsFromHosted(items: ChatItem[]): PreviewChatItem[] {
  const now = Date.now();
  return items.map(item => {
    if (item.type === 'user') {
      return {
        id: item.id,
        type: 'user',
        content: item.content,
        timestamp: now,
      };
    }
    if (item.type === 'agent') {
      return {
        id: item.id,
        type: 'agent',
        content: item.content,
        timestamp: now,
      };
    }
    if (item.type === 'error') {
      return {
        id: item.id,
        type: 'system',
        content: item.message,
        timestamp: now,
      };
    }
    if (item.type === 'thinking') {
      return {
        id: item.id,
        type: 'system',
        content: item.content ?? 'Agent is thinking...',
        timestamp: now,
      };
    }
    if (item.type === 'tool_call') {
      return {
        id: item.id,
        type: 'system',
        content: item.result ?? `${item.status === 'running' ? 'Running' : 'Finished'} ${item.name}`,
        timestamp: now,
      };
    }
    if (item.type === 'ask_user') {
      return {
        id: item.id,
        type: 'system',
        content: item.text,
        timestamp: now,
      };
    }
    if (item.type === 'approval_needed') {
      return {
        id: item.id,
        type: 'system',
        content: item.description ?? `Approval needed for ${item.tool}`,
        timestamp: now,
      };
    }
    if (item.type === 'onboard_required') {
      return {
        id: item.id,
        type: 'system',
        content: 'Onboarding required before the agent can continue.',
        timestamp: now,
      };
    }
    if (item.type === 'onboard_success') {
      return {
        id: item.id,
        type: 'system',
        content: item.message,
        timestamp: now,
      };
    }
    if (item.type === 'plan_review') {
      return {
        id: item.id,
        type: 'system',
        content: item.plan_content,
        timestamp: now,
      };
    }
    if (item.type === 'ulw_turns_reached') {
      return {
        id: item.id,
        type: 'system',
        content: `ULW turn limit reached (${item.turns_used}/${item.max_turns}).`,
        timestamp: now,
      };
    }
    return {
      id: item.id,
      type: 'system',
      content: 'Agent activity received.',
      timestamp: now,
    };
  });
}

function mergePreviewItems(current: PreviewChatItem[], incoming: PreviewChatItem[]): PreviewChatItem[] {
  const next = [...current];
  for (const item of incoming) {
    const existingIndex = next.findIndex(existing => existing.id === item.id);
    if (existingIndex >= 0) {
      next[existingIndex] = { ...next[existingIndex], ...item };
    } else {
      next.push(item);
    }
  }
  return next;
}

function hostedConversationToPreview(conversation: Conversation): PreviewConversation {
  return {
    id: conversation.id,
    title: conversation.title,
    agentAddress: conversation.agentAddress,
    updatedAt: conversation.updatedAt,
    serverSession: conversation.serverSession,
    ui: previewItemsFromHosted(conversation.ui),
  };
}

export function AppShell() {
  const insets = useSafeAreaInsets();
  const [tab, setTab] = useState<AppTab>('agents');
  const [isAddingAgent, setIsAddingAgent] = useState(false);
  const [isChatOpen, setIsChatOpen] = useState(false);
  const [draft, setDraft] = useState('');
  const [tokenDraft, setTokenDraft] = useState('');
  const [prompt, setPrompt] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [connectionError, setConnectionError] = useState<UserFacingError | null>(null);
  const [isConnecting, setIsConnecting] = useState(false);
  const [conversations, setConversations] = useState<PreviewConversation[]>([]);
  const [activeConversationId, setActiveConversationId] = useState<string | null>(null);
  const [connectBackTarget, setConnectBackTarget] = useState<AppTab | null>(null);
  const [keyboardVisible, setKeyboardVisible] = useState(false);
  const [identity, setIdentity] = useState<StoredIdentity | null>(null);
  const [activeAgentToken, setActiveAgentToken] = useState<StoredAgentToken | null>(null);
  const [isSending, setIsSending] = useState(false);

  const activeConversation = useMemo(
    () => conversations.find(conversation => conversation.id === activeConversationId) ?? null,
    [activeConversationId, conversations],
  );
  const connectionState: PreviewConnectionState = activeConversation ? 'connected' : 'disconnected';

  // Mirrors the old hook's persistence approach: write the conversation through
  // sessionRepository every time it changes, and remember which one is active.
  const persist = useCallback((conversation: PreviewConversation) => {
    saveConversation(toHostedConversation(conversation)).catch(() => {
      setError('Could not save the conversation.');
    });
  }, []);

  const upsertConversation = useCallback((next: PreviewConversation) => {
    setConversations(current => {
      const without = current.filter(conversation => conversation.id !== next.id);
      return [next, ...without].sort((a, b) => b.updatedAt - a.updatedAt);
    });
    persist(next);
  }, [persist]);

  const selectActive = useCallback((id: string | null) => {
    setActiveConversationId(id);
    if (id) {
      saveActiveConversationId(id).catch(() => undefined);
    }
  }, []);

  // Hydrate saved conversations on launch so history survives an app restart.
  useEffect(() => {
    let mounted = true;
    Promise.all([listConversations(), loadActiveConversationId()])
      .then(([stored, storedActiveId]) => {
        if (!mounted) {
          return;
        }
        const restored = stored.map(hostedConversationToPreview);
        setConversations(restored);
        if (storedActiveId && restored.some(conversation => conversation.id === storedActiveId)) {
          setActiveConversationId(storedActiveId);
        }
      })
      .catch(() => {
        if (mounted) {
          setError('Could not load saved conversations.');
        }
      });
    return () => {
      mounted = false;
    };
  }, []);

  // Flush the active conversation when the app is backgrounded, so an OS kill
  // mid-session does not lose the latest messages.
  useEffect(() => {
    const subscription = AppState.addEventListener('change', state => {
      if ((state === 'background' || state === 'inactive') && activeConversation) {
        persist(activeConversation);
      }
    });
    return () => subscription.remove();
  }, [activeConversation, persist]);

  useEffect(() => {
    let mounted = true;
    loadOrCreateIdentity()
      .then(value => {
        if (mounted) {
          setIdentity(value);
        }
      })
      .catch(() => {
        if (mounted) {
          setError('Could not load device identity.');
        }
      });
    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    let mounted = true;
    const agentAddress = activeConversation?.agentAddress;
    if (!agentAddress) {
      setActiveAgentToken(null);
      return () => {
        mounted = false;
      };
    }

    loadAgentTokenMetadata(agentAddress)
      .then(value => {
        if (mounted) {
          setActiveAgentToken(value);
        }
      })
      .catch(() => {
        if (mounted) {
          setActiveAgentToken(null);
        }
      });
    return () => {
      mounted = false;
    };
  }, [activeConversation?.agentAddress]);

  useEffect(() => {
    const showSubscription = Keyboard.addListener('keyboardWillShow', () => setKeyboardVisible(true));
    const hideSubscription = Keyboard.addListener('keyboardWillHide', () => setKeyboardVisible(false));
    return () => {
      showSubscription.remove();
      hideSubscription.remove();
    };
  }, []);

  const openAddAgent = useCallback((backTarget: AppTab | null = 'agents', initialDraft?: string) => {
    setDraft(initialDraft ?? '');
    setTokenDraft('');
    setError(null);
    setConnectionError(null);
    setConnectBackTarget(backTarget);
    setIsAddingAgent(true);
    setIsChatOpen(false);
  }, []);

  const handleConnect = async () => {
    if (isConnecting) {
      return;
    }

    const normalized = draft.trim();
    if (!isHostedAgentAddress(normalized)) {
      setConnectionError(invalidAddressError());
      return;
    }

    const token = tokenDraft.trim();
    if (token) {
      try {
        setActiveAgentToken(await saveAgentToken(normalized, token));
        setTokenDraft('');
      } catch {
        setConnectionError({
          kind: 'unknown',
          title: 'Could not save token',
          message: 'We could not securely save the access token. Please try again.',
          actions: ['retry', 'dismiss'],
        });
        return;
      }
    }

    // Verify the agent is actually reachable before opening the chat, so network
    // loss, timeouts and unreachable endpoints surface as plain-language errors.
    setConnectionError(null);
    setIsConnecting(true);
    let result;
    try {
      result = await testAgentConnectionForm({ agentAddress: normalized });
    } catch (err) {
      setIsConnecting(false);
      setConnectionError(toUserFacingError(err));
      return;
    }
    setIsConnecting(false);
    if (!result.ok) {
      setConnectionError(toUserFacingError(result.message));
      return;
    }

    setConnectionError(null);
    const existing = conversations.find(conversation => conversation.agentAddress === normalized);
    const now = Date.now();
    const nextConversation = existing
      ? { ...existing, updatedAt: now }
      : starterConversation(normalized);

    upsertConversation(nextConversation);
    selectActive(nextConversation.id);
    setConnectBackTarget(null);
    setIsAddingAgent(false);
    setIsChatOpen(true);
  };

  const handleSend = async () => {
    if (!activeConversation) {
      return;
    }
    if (isSending) {
      return;
    }

    const trimmed = prompt.trim();
    if (!trimmed) {
      return;
    }

    const now = Date.now();
    const requestConversation = toHostedConversation(activeConversation);
    const userMessage: PreviewChatItem = {
      id: makeId('user'),
      type: 'user',
      content: trimmed,
      timestamp: now,
    };

    // Track the conversation locally so each async step appends to the latest
    // state (activeConversation from the closure is stale after the first save).
    let latest: PreviewConversation = {
      ...activeConversation,
      title: activeConversation.ui.length === 0 ? titleFromPrompt(trimmed) : activeConversation.title,
      updatedAt: now,
      ui: [...activeConversation.ui, userMessage],
    };
    upsertConversation(latest);
    setPrompt('');
    setIsSending(true);

    try {
      const result = await sendPromptToHostedAgent(
        activeConversation.agentAddress,
        requestConversation,
        trimmed,
        [],
      );
      const responseItems = previewItemsFromHosted(result.items);
      latest = {
        ...latest,
        updatedAt: Date.now(),
        serverSession: result.serverSession ?? latest.serverSession,
        ui: mergePreviewItems(latest.ui, responseItems),
      };
      upsertConversation(latest);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'The agent did not respond.';
      const errorItem: PreviewChatItem = {
        id: makeId('error'),
        type: 'system',
        content: message,
        timestamp: Date.now(),
      };
      latest = {
        ...latest,
        updatedAt: Date.now(),
        ui: [...latest.ui, errorItem],
      };
      upsertConversation(latest);
    } finally {
      setIsSending(false);
    }
  };

  const handleOpenConversation = (conversationId: string) => {
    selectActive(conversationId);
    setIsChatOpen(true);
  };

  const handleDeleteConversation = (conversationId: string) => {
    setConversations(current => current.filter(conversation => conversation.id !== conversationId));
    if (activeConversationId === conversationId) {
      const fallback = conversations.find(conversation => conversation.id !== conversationId);
      selectActive(fallback ? fallback.id : null);
    }
    // deleteConversation removes the row, fixes the stored active id, and cascades
    // the agent secrets cleanup in sessionRepository.
    deleteConversation(conversationId).catch(() => undefined);
  };

  const handleReconnect = () => openAddAgent('settings', activeConversation?.agentAddress ?? '');

  const handleErrorAction = (action: ErrorAction) => {
    if (action === 'retry') {
      handleConnect();
      return;
    }
    // Both "edit connection" and "dismiss" clear the error and leave the user on
    // the form so they can correct the address or token.
    setConnectionError(null);
  };

  const handleConnectBack = () => {
    setTokenDraft('');
    setConnectionError(null);
    setIsAddingAgent(false);
    if (connectBackTarget) {
      setTab(connectBackTarget);
      return;
    }
    setTab('agents');
  };

  const handleCreate = () => {
    if (!activeConversation?.agentAddress) {
      return;
    }

    const nextConversation = starterConversation(activeConversation.agentAddress);
    upsertConversation(nextConversation);
    selectActive(nextConversation.id);
    setPrompt('');
  };

  const handleAddAgent = () => openAddAgent('agents');

  const handleBackupSeed = useCallback(async () => {
    try {
      return await exportIdentitySeed();
    } catch {
      setError('Could not read device identity.');
      return null;
    }
  }, []);

  const handleImportSeed = useCallback(async (seedHex: string) => {
    try {
      const nextIdentity = await importIdentitySeed(seedHex);
      setIdentity(nextIdentity);
      setError(null);
      return nextIdentity;
    } catch {
      setError('Could not import that seed.');
      return null;
    }
  }, []);

  const handleResetIdentity = useCallback(async () => {
    try {
      await resetIdentity();
      const nextIdentity = await loadOrCreateIdentity();
      setIdentity(nextIdentity);
      setError(null);
      return nextIdentity;
    } catch {
      setError('Could not reset device identity.');
      return null;
    }
  }, []);

  const changeTab = useCallback((nextTab: AppTab) => {
    setError(null);
    setConnectionError(null);
    setConnectBackTarget(null);
    setIsAddingAgent(false);
    setIsChatOpen(false);
    setTab(nextTab);
  }, []);

  return (
    <KeyboardAvoidingView
      style={[styles.shell, { paddingTop: insets.top }]}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={0}
    >
      {isChatOpen ? (
        <View
          pointerEvents="none"
          style={[styles.chatBackdrop, { top: insets.top }]}
        />
      ) : null}
      <View style={styles.body}>
        {isChatOpen ? (
          <ChatScreen
            active={activeConversation}
            connectionState={connectionState}
            prompt={prompt}
            bottomInset={insets.bottom}
            onBack={() => setIsChatOpen(false)}
            onPromptChange={setPrompt}
            onSend={handleSend}
            onCreate={handleCreate}
          />
        ) : null}

        {!isChatOpen && isAddingAgent ? (
          <AddAgentScreen
            draft={draft}
            tokenDraft={tokenDraft}
            error={error}
            connectionError={connectionError}
            busy={isConnecting}
            onDraftChange={setDraft}
            onTokenDraftChange={setTokenDraft}
            onConnect={handleConnect}
            onErrorAction={handleErrorAction}
            onBack={handleConnectBack}
            showBack
          />
        ) : null}

        {!isChatOpen && !isAddingAgent && tab === 'agents' ? (
          <AgentsScreen
            conversations={conversations}
            activeId={activeConversationId}
            connectionState={connectionState}
            onAddAgent={handleAddAgent}
            onSelect={handleOpenConversation}
          />
        ) : null}

        {!isChatOpen && !isAddingAgent && tab === 'history' ? (
          <HistoryScreen
            conversations={conversations}
            onSelect={handleOpenConversation}
            onDelete={handleDeleteConversation}
          />
        ) : null}

        {!isChatOpen && !isAddingAgent && tab === 'settings' ? (
          <SettingsScreen
            active={activeConversation}
            conversations={conversations}
            connectionState={connectionState}
            identity={identity}
            activeAgentToken={activeAgentToken}
            lastOutbound={null}
            onReconnect={handleReconnect}
            onBackupSeed={handleBackupSeed}
            onImportSeed={handleImportSeed}
            onResetIdentity={handleResetIdentity}
          />
        ) : null}
      </View>
      {isChatOpen || isAddingAgent || keyboardVisible ? null : (
        <TabBar value={tab} bottomInset={insets.bottom} onChange={changeTab} />
      )}
    </KeyboardAvoidingView>
  );
}
