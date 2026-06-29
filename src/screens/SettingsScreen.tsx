import React from 'react';
import { Pressable, ScrollView, Text, View } from 'react-native';
import { styles } from '../styles/appStyles';
import { compactJson, shortAddress } from '../utils/format';
import type { PreviewConnectionState, PreviewConversation } from '../app/previewTypes';

export function SettingsScreen(props: {
  active: PreviewConversation | null;
  conversations: PreviewConversation[];
  connectionState: PreviewConnectionState;
  identity: { address: string; publicKeyHex: string } | null;
  lastOutbound: unknown;
  onReconnect: () => void;
}) {
  const agentCount = new Set(
    props.conversations
      .map(conversation => conversation.agentAddress.trim().toLowerCase())
      .filter(Boolean),
  ).size;
  const messageCount = props.conversations.reduce(
    (total, conversation) => total + conversation.ui.filter(item => item.type === 'user' || item.type === 'agent').length,
    0,
  );
  const status = getAgentStatus(Boolean(props.active?.agentAddress), props.connectionState);

  return (
    <ScrollView
      style={styles.screenScroll}
      contentContainerStyle={styles.screenContent}
      alwaysBounceVertical
      keyboardShouldPersistTaps="handled"
      keyboardDismissMode="interactive"
    >
      <Text style={styles.largeTitle}>Settings</Text>

      <Text style={styles.sectionKicker}>Account</Text>
      <View style={styles.groupedList}>
        <View style={styles.settingsConnectionRow}>
          <View style={[styles.statusDot, status.dotStyle]} />
          <View style={styles.listMain}>
            <Text style={styles.listTitle}>Connection</Text>
            <Text numberOfLines={1} style={styles.listMeta}>{props.active?.title ?? 'No active agent'}</Text>
          </View>
          <Text style={[styles.statusText, status.textStyle]}>{status.label}</Text>
        </View>
        <View style={styles.listSeparator} />
        <View style={styles.settingsRowTall}>
          <View style={styles.listMain}>
            <Text style={styles.label}>Session ID</Text>
            <Text numberOfLines={1} style={styles.valueText}>{props.active?.id ?? 'None'}</Text>
          </View>
        </View>
        {props.active?.agentAddress ? (
          <>
            <View style={styles.listSeparator} />
            <Pressable
              style={({ pressed }) => [styles.settingsActionRow, pressed && styles.listRowPressed]}
              onPress={props.onReconnect}
            >
              <Text style={styles.settingsActionText}>Reconnect</Text>
            </Pressable>
          </>
        ) : null}
        <View style={styles.listSeparator} />
        <View style={styles.settingsMetricsRow}>
          <View style={styles.settingsMetric}>
            <Text style={styles.settingsMetricValue}>{agentCount}</Text>
            <Text style={styles.settingsMetricLabel}>Agents</Text>
          </View>
          <View style={styles.settingsMetricDivider} />
          <View style={styles.settingsMetric}>
            <Text style={styles.settingsMetricValue}>{messageCount}</Text>
            <Text style={styles.settingsMetricLabel}>Messages</Text>
          </View>
        </View>
      </View>

      <Text style={styles.sectionKicker}>Identity</Text>
      <View style={styles.groupedList}>
        <View style={styles.settingsRowTall}>
          <View style={styles.listMain}>
            <Text style={styles.label}>Device Identity Address</Text>
            <Text numberOfLines={1} style={styles.valueText}>{props.identity?.address ?? 'Creating...'}</Text>
          </View>
        </View>
        <View style={styles.listSeparator} />
        <View style={styles.settingsRowTall}>
          <View style={styles.listMain}>
            <Text style={styles.label}>Public Key</Text>
            <Text numberOfLines={1} style={styles.valueText}>{props.identity?.publicKeyHex ?? 'Pending'}</Text>
          </View>
        </View>
      </View>

      <Text style={styles.sectionKicker}>Agents</Text>
      <View style={styles.groupedList}>
        <View style={styles.settingsAgentRow}>
          <View style={[styles.statusDot, status.dotStyle]} />
          <View style={styles.listMain}>
            <Text numberOfLines={1} style={styles.listTitle}>{props.active?.title ?? 'No active agent'}</Text>
            <Text numberOfLines={1} style={styles.listMeta}>
              {props.active?.agentAddress ? shortAddress(props.active.agentAddress) : status.label}
            </Text>
          </View>
          <Text style={styles.listMeta}>{agentCount} {agentCount === 1 ? 'agent' : 'agents'}</Text>
        </View>
      </View>

      <Text style={styles.sectionKicker}>Developer</Text>
      <View style={styles.codeCard}>
        <Text style={styles.label}>Last outbound frame</Text>
        <Text style={styles.codeText}>{compactJson(props.lastOutbound)}</Text>
      </View>
    </ScrollView>
  );
}

function getAgentStatus(hasActiveAgent: boolean, connectionState: PreviewConnectionState) {
  if (!hasActiveAgent || connectionState === 'disconnected') {
    return { label: 'Disconnected', dotStyle: styles.statusDotSaved, textStyle: styles.statusTextSaved };
  }
  return { label: 'Connected', dotStyle: styles.statusDotLive, textStyle: styles.statusTextLive };
}
