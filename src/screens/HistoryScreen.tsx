import React, { useMemo, useRef, useState } from 'react';
import { Alert, Animated, Image, PanResponder, Pressable, ScrollView, Text, TextInput, View } from 'react-native';
import { styles } from '../styles/appStyles';
import { formatTime, shortAddress } from '../utils/format';
import type { PreviewConversation } from '../app/previewTypes';

const searchIcon = require('../assets/icons/search.png');
const DELETE_ACTION_WIDTH = 86;

export function HistoryScreen(props: {
  conversations: PreviewConversation[];
  onSelect: (id: string) => void;
  onDelete: (id: string) => void;
}) {
  const [query, setQuery] = useState('');
  const [searchFocused, setSearchFocused] = useState(false);
  const isSearching = query.trim().length > 0;

  const visibleConversations = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    return props.conversations.filter(conversation => {
      if (!normalized) {
        return true;
      }
      return (
        conversation.title.toLowerCase().includes(normalized) ||
        conversation.agentAddress.toLowerCase().includes(normalized)
      );
    });
  }, [props.conversations, query]);

  return (
    <View style={styles.tabScreen}>
      <ScrollView
        style={styles.screenScroll}
        contentContainerStyle={styles.screenContent}
        alwaysBounceVertical
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="interactive"
      >
        <Text style={styles.largeTitle}>History</Text>
        <SearchBox
          value={query}
          onChange={setQuery}
          onFocus={() => setSearchFocused(true)}
          onBlur={() => setSearchFocused(false)}
          placeholder="Search conversations"
        />
        {visibleConversations.length === 0 ? (
          <View style={[styles.emptyState, searchFocused && styles.emptyStateCompact]}>
            <Text style={styles.emptyTitle}>{isSearching ? 'No matching conversations' : 'No conversations yet'}</Text>
            <Text style={styles.emptyBody}>
              {isSearching ? 'Try another search.' : 'Connect to an agent and your recent chats will appear here.'}
            </Text>
          </View>
        ) : (
          <View style={styles.groupedList}>
            {visibleConversations.map((conversation, index) => (
              <View key={conversation.id}>
                <SwipeableHistoryRow
                  conversation={conversation}
                  onSelect={() => props.onSelect(conversation.id)}
                  onDelete={() => props.onDelete(conversation.id)}
                />
                {index < visibleConversations.length - 1 ? <View style={styles.listSeparator} /> : null}
              </View>
            ))}
          </View>
        )}
      </ScrollView>
    </View>
  );
}

function SwipeableHistoryRow(props: {
  conversation: PreviewConversation;
  onSelect: () => void;
  onDelete: () => void;
}) {
  const translateX = useRef(new Animated.Value(0)).current;
  const gestureStart = useRef(0);

  function settleRow(open: boolean) {
    Animated.spring(translateX, {
      toValue: open ? -DELETE_ACTION_WIDTH : 0,
      useNativeDriver: true,
      damping: 22,
      stiffness: 240,
      mass: 0.8,
    }).start();
  }

  const panResponder = useRef(PanResponder.create({
    onMoveShouldSetPanResponder: (_, gesture) => (
      Math.abs(gesture.dx) > 8 && Math.abs(gesture.dx) > Math.abs(gesture.dy)
    ),
    onPanResponderGrant: () => {
      translateX.stopAnimation(value => {
        gestureStart.current = value;
      });
    },
    onPanResponderMove: (_, gesture) => {
      const next = Math.max(-DELETE_ACTION_WIDTH, Math.min(0, gestureStart.current + gesture.dx));
      translateX.setValue(next);
    },
    onPanResponderRelease: (_, gesture) => {
      settleRow(gestureStart.current + gesture.dx < -DELETE_ACTION_WIDTH / 2);
    },
    onPanResponderTerminate: () => settleRow(false),
  })).current;

  function confirmDelete() {
    Alert.alert(
      'Delete conversation?',
      props.conversation.title,
      [
        { text: 'Cancel', style: 'cancel', onPress: () => settleRow(false) },
        { text: 'Delete', style: 'destructive', onPress: props.onDelete },
      ],
    );
  }

  return (
    <View style={styles.swipeRow}>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={`Delete ${props.conversation.title}`}
        style={({ pressed }) => [styles.swipeDeleteAction, pressed && styles.pressablePressed]}
        onPress={confirmDelete}
      >
        <Text style={styles.swipeDeleteText}>Delete</Text>
      </Pressable>
      <Animated.View
        {...panResponder.panHandlers}
        style={[styles.swipeRowFront, { transform: [{ translateX }] }]}
      >
        <Pressable
          style={({ pressed }) => [styles.historyRow, pressed && styles.listRowPressed]}
          onPress={props.onSelect}
        >
          <View style={styles.historyMain}>
            <Text numberOfLines={1} style={styles.listTitle}>{props.conversation.title}</Text>
            <Text numberOfLines={1} style={styles.listMeta}>
              {conversationDetails(props.conversation)}
            </Text>
          </View>
        </Pressable>
      </Animated.View>
    </View>
  );
}

function conversationDetails(conversation: PreviewConversation): string {
  return [
    conversation.agentAddress ? shortAddress(conversation.agentAddress) : null,
    `${conversation.ui.length} items`,
    formatTime(conversation.updatedAt),
  ].filter((value): value is string => Boolean(value)).join(' · ');
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
