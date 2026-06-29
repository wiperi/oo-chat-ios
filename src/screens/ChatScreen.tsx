import React, { useRef } from 'react';
import { Pressable, ScrollView, Text, View } from 'react-native';
import { ChatItemView } from '../components/chat/ChatItemView';
import { Composer } from '../components/chat/Composer';
import { BackChevron } from '../components/layout/BackChevron';
import { styles } from '../styles/appStyles';
import type { PreviewConnectionState, PreviewConversation } from '../app/previewTypes';

export function ChatScreen(props: {
  active: PreviewConversation | null;
  connectionState: PreviewConnectionState;
  prompt: string;
  bottomInset: number;
  onBack: () => void;
  onPromptChange: (value: string) => void;
  onSend: () => void;
  onCreate: () => void;
}) {
  const scrollViewRef = useRef<ScrollView>(null);

  if (!props.active) {
    return (
      <View style={styles.fullScreen}>
        <View style={styles.chatHeader}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Back"
            style={({ pressed }) => [styles.backButton, pressed && styles.pressablePressed]}
            onPress={props.onBack}
          >
            <BackChevron />
          </Pressable>
          <Text style={styles.contextTitle}>Chat</Text>
          <View style={styles.headerSpacer} />
        </View>
        <Text style={styles.emptyText}>No conversation selected.</Text>
      </View>
    );
  }

  const active = props.active;

  return (
    <View style={styles.chatLayout}>
      <View style={styles.chatHeader}>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Back"
          style={({ pressed }) => [styles.backButton, pressed && styles.pressablePressed]}
          onPress={props.onBack}
        >
          <BackChevron />
        </Pressable>
        <View style={styles.chatHeaderTitleBlock}>
          <Text numberOfLines={1} style={styles.chatTitle}>{active.title}</Text>
          <View style={styles.chatStatusRow}>
            <View style={[styles.chatStatusDot, statusDotStyle(props.connectionState)]} />
            <Text style={statusTextStyle(props.connectionState)}>
              {connectionLabel(props.connectionState)}
            </Text>
          </View>
        </View>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="New chat"
          style={({ pressed }) => [styles.chatHeaderAction, pressed && styles.pressablePressed]}
          onPress={props.onCreate}
        >
          <Text style={styles.chatHeaderActionText}>New</Text>
        </Pressable>
      </View>
      <ScrollView
        ref={scrollViewRef}
        style={styles.messages}
        contentContainerStyle={styles.messagesContent}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="interactive"
        showsVerticalScrollIndicator={false}
        onContentSizeChange={() => scrollViewRef.current?.scrollToEnd({ animated: true })}
      >
        {active.ui.map(item => (
          <ChatItemView key={item.id} item={item} />
        ))}
      </ScrollView>
      <Composer
        value={props.prompt}
        disabled={false}
        bottomInset={props.bottomInset}
        onChange={props.onPromptChange}
        onSend={props.onSend}
      />
    </View>
  );
}

function connectionLabel(connectionState: PreviewConnectionState): string {
  if (connectionState === 'connected') {
    return 'Connected';
  }
  return 'Disconnected';
}

function statusDotStyle(connectionState: PreviewConnectionState) {
  if (connectionState === 'connected') {
    return styles.statusDotLive;
  }
  return styles.statusDotSaved;
}

function statusTextStyle(connectionState: PreviewConnectionState) {
  if (connectionState === 'connected') {
    return styles.chatStatusTextLive;
  }
  return styles.chatStatusTextSaved;
}
