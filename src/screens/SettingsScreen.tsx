import React from 'react';
import { Alert, Pressable, ScrollView, Share, Text, View } from 'react-native';
import { styles } from '../styles/appStyles';
import { compactJson, shortAddress } from '../utils/format';
import type { PreviewConnectionState, PreviewConversation } from '../app/previewTypes';
import type { StoredAgentToken } from '../storage/keyManager';
import type { StoredIdentity } from '../types';

export function SettingsScreen(props: {
  active: PreviewConversation | null;
  conversations: PreviewConversation[];
  connectionState: PreviewConnectionState;
  identity: StoredIdentity | null;
  activeAgentToken: StoredAgentToken | null;
  lastOutbound: unknown;
  onReconnect: () => void;
  onBackupSeed: () => Promise<string | null>;
  onImportSeed: (seedHex: string) => Promise<StoredIdentity | null>;
  onResetIdentity: () => Promise<StoredIdentity | null>;
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
  const activeAgentAddress = props.active?.agentAddress.trim();

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
        <View style={styles.listSeparator} />
        <Pressable
          style={({ pressed }) => [styles.settingsActionRow, pressed && styles.listRowPressed]}
          onPress={() => backupSeed(props.onBackupSeed)}
        >
          <Text style={styles.settingsActionText}>Backup Seed</Text>
        </Pressable>
        <View style={styles.listSeparator} />
        <Pressable
          style={({ pressed }) => [styles.settingsActionRow, pressed && styles.listRowPressed]}
          onPress={() => importSeed(props.onImportSeed)}
        >
          <Text style={styles.settingsActionText}>Import Seed</Text>
        </Pressable>
        <View style={styles.listSeparator} />
        <Pressable
          style={({ pressed }) => [styles.settingsActionRow, pressed && styles.listRowPressed]}
          onPress={() => resetIdentity(props.onResetIdentity)}
        >
          <Text style={styles.settingsDangerText}>Reset Identity</Text>
        </Pressable>
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

      <Text style={styles.sectionKicker}>Security</Text>
      <View style={styles.groupedList}>
        <View style={styles.settingsRowTall}>
          <View style={styles.listMain}>
            <Text style={styles.label}>Current Agent Credential</Text>
            <Text numberOfLines={1} style={styles.valueText}>
              {activeAgentAddress
                ? props.activeAgentToken ? 'Stored in Keychain' : 'Not saved'
                : 'No active agent'}
            </Text>
          </View>
        </View>
        {activeAgentAddress && props.activeAgentToken ? (
          <>
            <View style={styles.listSeparator} />
            <View style={styles.settingsRowTall}>
              <View style={styles.listMain}>
                <Text style={styles.label}>Updated</Text>
                <Text numberOfLines={1} style={styles.valueText}>{formatDate(props.activeAgentToken.updatedAt)}</Text>
              </View>
            </View>
          </>
        ) : null}
      </View>

      <Text style={styles.sectionKicker}>Developer</Text>
      <View style={styles.codeCard}>
        <Text style={styles.label}>Last outbound frame</Text>
        <Text style={styles.codeText}>{compactJson(props.lastOutbound)}</Text>
      </View>
    </ScrollView>
  );
}

async function backupSeed(loadSeed: () => Promise<string | null>) {
  const seed = await loadSeed();
  if (!seed) {
    return;
  }
  await Share.share({ message: seed }).catch(() => {
    Alert.alert('Seed', seed);
  });
}

function importSeed(importSeedHex: (seedHex: string) => Promise<StoredIdentity | null>) {
  Alert.prompt(
    'Import Seed',
    'Paste the 32-byte recovery seed.',
    [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Import',
        onPress: (value?: string) => {
          const seed = value?.trim();
          if (seed) {
            importSeedHex(seed);
          }
        },
      },
    ],
    'plain-text',
  );
}

function resetIdentity(reset: () => Promise<StoredIdentity | null>) {
  Alert.alert(
    'Reset Identity',
    'This replaces the device identity stored in Keychain.',
    [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Reset', style: 'destructive', onPress: () => { reset(); } },
    ],
  );
}

function formatDate(value: number) {
  if (!value) {
    return 'Unknown';
  }
  return new Date(value).toLocaleString([], {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function getAgentStatus(hasActiveAgent: boolean, connectionState: PreviewConnectionState) {
  if (!hasActiveAgent || connectionState === 'disconnected') {
    return { label: 'Disconnected', dotStyle: styles.statusDotSaved, textStyle: styles.statusTextSaved };
  }
  return { label: 'Connected', dotStyle: styles.statusDotLive, textStyle: styles.statusTextLive };
}
