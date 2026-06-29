import React, { useMemo, useState } from 'react';
import { Image, Pressable, ScrollView, Text, TextInput, View } from 'react-native';
import { styles } from '../styles/appStyles';
import { shortAddress } from '../utils/format';
import type { PreviewConnectionState, PreviewConversation } from '../app/previewTypes';

const chevronIcon = require('../assets/icons/chevron-right.png');
const logoIcon = require('../assets/icons/connectonion-logo.png');
const searchIcon = require('../assets/icons/search.png');

interface AgentGroup {
  address: string;
  conversations: PreviewConversation[];
  latestConversation: PreviewConversation;
}

export function AgentsScreen(props: {
  conversations: PreviewConversation[];
  activeId: string | null;
  connectionState: PreviewConnectionState;
  onAddAgent: () => void;
  onSelect: (id: string) => void;
}) {
  const [query, setQuery] = useState('');
  const [searchFocused, setSearchFocused] = useState(false);
  const isSearching = query.trim().length > 0;
  const agents = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    const groups = new Map<string, AgentGroup>();

    props.conversations.forEach(conversation => {
      const address = conversation.agentAddress.trim();
      if (!address) {
        return;
      }

      const key = address.toLowerCase();
      const existing = groups.get(key);
      if (!existing) {
        groups.set(key, {
          address,
          conversations: [conversation],
          latestConversation: conversation,
        });
        return;
      }

      existing.conversations.push(conversation);
      if (conversation.updatedAt > existing.latestConversation.updatedAt) {
        existing.latestConversation = conversation;
      }
    });

    return Array.from(groups.values())
      .sort((a, b) => b.latestConversation.updatedAt - a.latestConversation.updatedAt)
      .filter(agent => {
        if (!normalized) {
          return true;
        }
        return (
          agent.address.toLowerCase().includes(normalized) ||
          agent.conversations.some(conversation => conversation.title.toLowerCase().includes(normalized))
        );
      });
  }, [props.conversations, query]);

  const activeAddress = props.conversations
    .find(conversation => conversation.id === props.activeId)
    ?.agentAddress.trim().toLowerCase();

  return (
    <View style={styles.tabScreen}>
      <View style={styles.brandHeader}>
        <View style={styles.logoMark}>
          <Image source={logoIcon} style={styles.logoImage} resizeMode="contain" />
        </View>
        <Text style={styles.brand}>ConnectOnion</Text>
      </View>
      <ScrollView
        style={styles.screenScroll}
        contentContainerStyle={styles.screenContent}
        alwaysBounceVertical
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="interactive"
      >
        <SearchBox
          value={query}
          onChange={setQuery}
          onFocus={() => setSearchFocused(true)}
          onBlur={() => setSearchFocused(false)}
          placeholder="Search agents..."
        />
        {agents.length === 0 ? (
          <View style={[styles.emptyState, searchFocused && styles.emptyStateCompact]}>
            <Text style={styles.emptyTitle}>{isSearching ? 'No matching agents' : 'No agents yet'}</Text>
            <Text style={styles.emptyBody}>
              {isSearching ? 'Try another search.' : 'Add a hosted agent address to start chatting from your iPhone.'}
            </Text>
          </View>
        ) : (
          <View style={styles.groupedList}>
            {agents.map((agent, index) => {
              const status = getAgentStatus(agent.address.toLowerCase() === activeAddress, props.connectionState);
              const conversationCount = agent.conversations.length;

              return (
                <View key={agent.address.toLowerCase()}>
                  <Pressable
                    accessibilityRole="button"
                    style={({ pressed }) => [styles.agentRow, pressed && styles.listRowPressed]}
                    onPress={() => props.onSelect(agent.latestConversation.id)}
                  >
                    <View style={styles.agentIconTile}>
                      <AgentGlyph />
                    </View>
                    <View style={styles.listMain}>
                      <Text numberOfLines={1} style={styles.listTitle}>{shortAddress(agent.address)}</Text>
                      <Text numberOfLines={1} style={styles.listMeta}>
                        {conversationCount} {conversationCount === 1 ? 'conversation' : 'conversations'}
                      </Text>
                    </View>
                    <View style={styles.statusWrap}>
                      <View style={[styles.statusDot, status.style]} />
                      <Text style={[styles.statusText, status.textStyle]}>{status.label}</Text>
                    </View>
                    <ChevronGlyph />
                  </Pressable>
                  {index < agents.length - 1 ? <View style={styles.listSeparator} /> : null}
                </View>
              );
            })}
          </View>
        )}
      </ScrollView>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Add agent"
        style={({ pressed }) => [styles.fab, pressed && styles.pressablePressed]}
        onPress={props.onAddAgent}
      >
        <View style={styles.fabPlus}>
          <View style={styles.fabPlusHorizontal} />
          <View style={styles.fabPlusVertical} />
        </View>
      </Pressable>
    </View>
  );
}

function ChevronGlyph() {
  return <Image source={chevronIcon} style={styles.chevronImage} resizeMode="contain" />;
}

function getAgentStatus(isActive: boolean, connectionState: PreviewConnectionState) {
  if (isActive && connectionState === 'connected') {
    return {
      label: 'Connected',
      style: styles.statusDotLive,
      textStyle: styles.statusTextLive,
    };
  }

  return {
    label: 'Saved',
    style: styles.statusDotSaved,
    textStyle: styles.statusTextSaved,
  };
}

function SearchBox(props: {
  value: string;
  onChange: (value: string) => void;
  onFocus: () => void;
  onBlur: () => void;
  placeholder: string;
}) {
  return (
    <View style={styles.searchBar}>
      <Image source={searchIcon} style={styles.searchIcon} resizeMode="contain" />
      <TextInput
        value={props.value}
        onChangeText={props.onChange}
        onFocus={props.onFocus}
        onBlur={props.onBlur}
        autoCapitalize="none"
        autoCorrect={false}
        placeholder={props.placeholder}
        placeholderTextColor="#7B8190"
        style={styles.searchInput}
      />
    </View>
  );
}

function AgentGlyph() {
  return (
    <View style={styles.agentGlyph}>
      <View style={styles.agentGlyphCore} />
      <View style={styles.agentGlyphRing} />
    </View>
  );
}
