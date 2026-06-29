import React from 'react';
import { Pressable, ScrollView, Text, TextInput, View } from 'react-native';
import { BackChevron } from '../components/layout/BackChevron';
import { ErrorBanner } from '../components/ErrorBanner';
import { styles } from '../styles/appStyles';
import type { ErrorAction, UserFacingError } from '../utils/errorMessages';

export function AddAgentScreen(props: {
  draft: string;
  tokenDraft: string;
  error?: string | null;
  connectionError?: UserFacingError | null;
  busy?: boolean;
  onDraftChange: (value: string) => void;
  onTokenDraftChange: (value: string) => void;
  onConnect: () => void;
  onErrorAction?: (action: ErrorAction) => void;
  onBack: () => void;
  showBack?: boolean;
}) {
  const showBack = props.showBack ?? true;
  const canSubmit = props.draft.trim().length > 0 && !props.busy;

  return (
    <View style={styles.fullScreen}>
      <View style={styles.contextHeader}>
        {showBack ? (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Back"
            style={({ pressed }) => [styles.backButton, pressed && styles.pressablePressed]}
            onPress={props.onBack}
          >
            <BackChevron />
          </Pressable>
        ) : (
          <View style={styles.headerSpacer} />
        )}
        <Text style={styles.contextTitle}>Add Agent</Text>
        <View style={styles.headerSpacer} />
      </View>
      <ScrollView
        style={styles.screenScroll}
        contentContainerStyle={styles.formContent}
        alwaysBounceVertical
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="interactive"
      >
        <Text style={styles.bodyCopy}>Paste a ConnectOnion agent address to start chatting.</Text>
        <View style={styles.formCard}>
          <Text style={styles.label}>Agent Address</Text>
          <TextInput
            value={props.draft}
            onChangeText={props.onDraftChange}
            autoCapitalize="none"
            autoCorrect={false}
            placeholder="Agent address"
            placeholderTextColor="#7B8190"
            returnKeyType="go"
            onSubmitEditing={canSubmit ? props.onConnect : undefined}
            style={styles.input}
          />
          <Text style={styles.helperText}>Use the hosted agent address provided by the agent.</Text>
        </View>
        <View style={styles.formCard}>
          <Text style={styles.label}>Access Token</Text>
          <TextInput
            value={props.tokenDraft}
            onChangeText={props.onTokenDraftChange}
            autoCapitalize="none"
            autoCorrect={false}
            secureTextEntry
            placeholder="Optional"
            placeholderTextColor="#7B8190"
            returnKeyType="go"
            onSubmitEditing={canSubmit ? props.onConnect : undefined}
            style={styles.input}
          />
          <Text style={styles.helperText}>Saved in Keychain and hidden after entry.</Text>
        </View>
        {props.connectionError ? (
          <ErrorBanner
            error={props.connectionError}
            onAction={action => props.onErrorAction?.(action)}
          />
        ) : props.error ? (
          <Text style={styles.errorBanner}>{props.error}</Text>
        ) : null}
        <Pressable
          disabled={!canSubmit}
          style={({ pressed }) => [
            styles.fullWidthPrimaryButton,
            !canSubmit && styles.fullWidthPrimaryButtonDisabled,
            pressed && styles.pressablePressed,
          ]}
          onPress={props.onConnect}
        >
          <Text style={styles.fullWidthPrimaryButtonText}>
            {props.busy ? 'Connecting…' : 'Connect'}
          </Text>
        </Pressable>
      </ScrollView>
    </View>
  );
}
