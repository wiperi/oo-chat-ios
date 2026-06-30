import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Keyboard, KeyboardAvoidingView, Platform, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { TabBar } from '../components/layout/TabBar';
import { AddAgentScreen } from '../screens/AddAgentScreen';
import { AgentsScreen } from '../screens/AgentsScreen';
import { ChatScreen } from '../screens/ChatScreen';
import { HistoryScreen } from '../screens/HistoryScreen';
import { SettingsScreen } from '../screens/SettingsScreen';
import {
  deleteAgentSecrets,
  exportIdentitySeed,
  importIdentitySeed,
  loadAgentTokenMetadata,
  loadOrCreateIdentity,
  resetIdentity,
  saveAgentToken,
  type StoredAgentToken,
} from '../storage/keyManager';
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
    const nextConversation = existing ?? starterConversation(normalized);

    setConversations(current => {
      if (existing) {
        return current
          .map(conversation =>
            conversation.id === existing.id
              ? { ...conversation, updatedAt: now }
              : conversation,
          )
          .sort((a, b) => b.updatedAt - a.updatedAt);
      }
      return [nextConversation, ...current];
    });
    setActiveConversationId(nextConversation.id);
    setConnectBackTarget(null);
    setIsAddingAgent(false);
    setIsChatOpen(true);
  };

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
      return {
        id: item.id,
        type: 'system',
        content: 'Agent activity received.',
        timestamp: now,
      };
    });
  }

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

    setConversations(current =>
      current
        .map(conversation =>
          conversation.id === activeConversation.id
              ? {
                  ...conversation,
                  title: conversation.ui.length === 0 ? titleFromPrompt(trimmed) : conversation.title,
                  updatedAt: now,
                  ui: [...conversation.ui, userMessage],
                }
            : conversation,
        )
        .sort((a, b) => b.updatedAt - a.updatedAt),
    );
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
      setConversations(current =>
        current.map(conversation =>
          conversation.id === activeConversation.id
            ? {
                ...conversation,
                updatedAt: Date.now(),
                serverSession: result.serverSession ?? conversation.serverSession,
                ui: [...conversation.ui, ...responseItems],
              }
            : conversation,
        ),
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : 'The agent did not respond.';
      const errorItem: PreviewChatItem = {
        id: makeId('error'),
        type: 'system',
        content: message,
        timestamp: Date.now(),
      };
      setConversations(current =>
        current.map(conversation =>
          conversation.id === activeConversation.id
            ? {
                ...conversation,
                updatedAt: Date.now(),
                ui: [...conversation.ui, errorItem],
              }
            : conversation,
        ),
      );
    } finally {
      setIsSending(false);
    }
  };

  const handleOpenConversation = (conversationId: string) => {
    setActiveConversationId(conversationId);
    setIsChatOpen(true);
  };

  const handleDeleteConversation = (conversationId: string) => {
    const target = conversations.find(conversation => conversation.id === conversationId);
    setConversations(current => {
      const next = current.filter(conversation => conversation.id !== conversationId);
      setActiveConversationId(activeId => {
        if (activeId !== conversationId) {
          return activeId;
        }
        return next[0]?.id ?? null;
      });
      return next;
    });
    if (target?.agentAddress) {
      deleteAgentSecrets(target.agentAddress).catch(() => undefined);
    }
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
    setConversations(current => [nextConversation, ...current]);
    setActiveConversationId(nextConversation.id);
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
