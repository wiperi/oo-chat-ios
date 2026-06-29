import React from 'react';
import { Pressable, Text, View } from 'react-native';
import { styles } from '../styles/appStyles';
import { actionLabel, type ErrorAction, type UserFacingError } from '../utils/errorMessages';

/**
 * Presents a plain-language connection error with its next actions. Pure
 * presenter: all copy and the action list come from the (unit-tested)
 * `errorMessages` translation layer.
 */
export function ErrorBanner(props: {
  error: UserFacingError;
  onAction: (action: ErrorAction) => void;
}) {
  const { error, onAction } = props;

  return (
    <View style={styles.errorCard} accessibilityRole="alert">
      <Text style={styles.errorCardTitle}>{error.title}</Text>
      <Text style={styles.errorCardMessage}>{error.message}</Text>
      <View style={styles.errorCardActions}>
        {error.actions.map(action => (
          <Pressable
            key={action}
            accessibilityRole="button"
            accessibilityLabel={actionLabel(action)}
            onPress={() => onAction(action)}
            style={({ pressed }) => [styles.errorActionButton, pressed && styles.pressablePressed]}
          >
            <Text style={styles.errorActionText}>{actionLabel(action)}</Text>
          </Pressable>
        ))}
      </View>
    </View>
  );
}
