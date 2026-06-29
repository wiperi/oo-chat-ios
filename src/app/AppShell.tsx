import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Keyboard, KeyboardAvoidingView, Platform, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { TabBar } from '../components/layout/TabBar';
import { AddAgentScreen } from '../screens/AddAgentScreen';
import { AgentsScreen } from '../screens/AgentsScreen';
import { ChatScreen } from '../screens/ChatScreen';
import { HistoryScreen } from '../screens/HistoryScreen';
import { SettingsScreen } from '../screens/SettingsScreen';
import { styles } from '../styles/appStyles';
import { shortAddress } from '../utils/format';
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
  const [prompt, setPrompt] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [conversations, setConversations] = useState<PreviewConversation[]>([]);
  const [activeConversationId, setActiveConversationId] = useState<string | null>(null);
  const [connectBackTarget, setConnectBackTarget] = useState<AppTab | null>(null);
  const [keyboardVisible, setKeyboardVisible] = useState(false);

  const activeConversation = useMemo(
    () => conversations.find(conversation => conversation.id === activeConversationId) ?? null,
    [activeConversationId, conversations],
  );
  const connectionState: PreviewConnectionState = activeConversation ? 'connected' : 'disconnected';

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
    setError(null);
    setConnectBackTarget(backTarget);
    setIsAddingAgent(true);
    setIsChatOpen(false);
  }, []);

  const handleConnect = () => {
    const normalized = draft.trim();
    if (!isHostedAgentAddress(normalized)) {
      setError('Enter a hosted agent address in 0x-prefixed Ed25519 format.');
      return;
    }

    setError(null);
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

  const handleSend = () => {
    if (!activeConversation) {
      return;
    }

    const trimmed = prompt.trim();
    if (!trimmed) {
      return;
    }

    const now = Date.now();
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
  };

  const handleOpenConversation = (conversationId: string) => {
    setActiveConversationId(conversationId);
    setIsChatOpen(true);
  };

  const handleDeleteConversation = (conversationId: string) => {
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
  };

  const handleReconnect = () => openAddAgent('settings', activeConversation?.agentAddress ?? '');

  const handleConnectBack = () => {
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

  const changeTab = useCallback((nextTab: AppTab) => {
    setError(null);
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
            error={error}
            onDraftChange={setDraft}
            onConnect={handleConnect}
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
            identity={null}
            lastOutbound={null}
            onReconnect={handleReconnect}
          />
        ) : null}
      </View>
      {isChatOpen || isAddingAgent || keyboardVisible ? null : (
        <TabBar value={tab} bottomInset={insets.bottom} onChange={changeTab} />
      )}
    </KeyboardAvoidingView>
  );
}
