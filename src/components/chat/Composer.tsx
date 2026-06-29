import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Image, Keyboard, Pressable, TextInput, View } from 'react-native';
import { styles } from '../../styles/appStyles';

const sendArrowIcon = require('../../assets/icons/send-arrow.png');

export function Composer(props: {
  value: string;
  disabled: boolean;
  bottomInset: number;
  onChange: (value: string) => void;
  onSend: () => void;
}) {
  const inputRef = useRef<TextInput>(null);
  const [keyboardVisible, setKeyboardVisible] = useState(false);
  const composerInsetStyle = useMemo(() => ({
    paddingBottom: keyboardVisible ? 10 : Math.max(10, props.bottomInset),
  }), [keyboardVisible, props.bottomInset]);

  useEffect(() => {
    const showSubscription = Keyboard.addListener('keyboardWillShow', () => setKeyboardVisible(true));
    const hideSubscription = Keyboard.addListener('keyboardWillHide', () => setKeyboardVisible(false));
    return () => {
      showSubscription.remove();
      hideSubscription.remove();
    };
  }, []);

  return (
    <View style={[styles.composer, composerInsetStyle]}>
      <View style={styles.inputRow}>
        <Pressable
          style={[styles.composerInputShell, props.disabled && styles.composerInputShellDisabled]}
          onPress={() => inputRef.current?.focus()}
        >
          <TextInput
            ref={inputRef}
            value={props.value}
            onChangeText={props.onChange}
            editable={!props.disabled}
            placeholder={props.disabled ? 'Waiting for current action' : 'Message...'}
            placeholderTextColor="#C7C3CF"
            selectionColor="#6D28D9"
            multiline
            returnKeyType="default"
            style={[styles.composerInput, props.disabled && styles.inputDisabled]}
          />
        </Pressable>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Send message"
          disabled={props.disabled || props.value.trim().length === 0}
          style={({ pressed }) => [
            styles.sendButton,
            (props.disabled || props.value.trim().length === 0) && styles.sendButtonDisabled,
            pressed && styles.pressablePressed,
          ]}
          onPress={props.onSend}
        >
          <Image source={sendArrowIcon} style={styles.sendArrowImage} resizeMode="contain" />
        </Pressable>
      </View>
    </View>
  );
}
