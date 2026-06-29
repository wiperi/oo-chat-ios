import React from 'react';
import { Image, Text, View } from 'react-native';
import { styles } from '../../styles/appStyles';
import { formatTime } from '../../utils/format';
import type { PreviewChatItem } from '../../app/previewTypes';

const logoIcon = require('../../assets/icons/connectonion-logo.png');

export function ChatItemView(props: { item: PreviewChatItem }) {
  const item = props.item;

  if (item.type === 'user') {
    return (
      <View style={styles.userMessageWrap}>
        <View style={[styles.bubble, styles.userBubble]}>
          <Text style={styles.userText}>{item.content}</Text>
          <Text style={styles.bubbleMetaUser}>{formatTime(item.timestamp)}</Text>
        </View>
      </View>
    );
  }

  if (item.type === 'agent') {
    return (
      <View style={styles.agentMessageRow}>
        <Image source={logoIcon} style={styles.chatAvatar} resizeMode="contain" />
        <View style={styles.agentMessageStack}>
          <View style={[styles.bubble, styles.agentBubble]}>
            <Text style={styles.agentText}>{item.content}</Text>
            <Text style={styles.bubbleMetaAgent}>{formatTime(item.timestamp)}</Text>
          </View>
        </View>
      </View>
    );
  }

  return (
    <View style={styles.activityRow}>
      <Text style={styles.activityTitle}>System</Text>
      <Text style={styles.activityBody}>{item.content}</Text>
    </View>
  );
}
