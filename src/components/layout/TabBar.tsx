import React from 'react';
import { Image, Pressable, Text, View } from 'react-native';
import type { ImageSourcePropType } from 'react-native';
import { styles } from '../../styles/appStyles';
import type { AppTab } from '../../app/tabs';

const tabs: Array<{ value: AppTab; label: string }> = [
  { value: 'agents', label: 'Agents' },
  { value: 'history', label: 'History' },
  { value: 'settings', label: 'Settings' },
];

const tabIcons: Record<AppTab, { active: ImageSourcePropType; inactive: ImageSourcePropType }> = {
  agents: {
    active: require('../../assets/icons/tab-agents-active.png'),
    inactive: require('../../assets/icons/tab-agents-inactive.png'),
  },
  history: {
    active: require('../../assets/icons/tab-history-active.png'),
    inactive: require('../../assets/icons/tab-history-inactive.png'),
  },
  settings: {
    active: require('../../assets/icons/tab-settings-active.png'),
    inactive: require('../../assets/icons/tab-settings-inactive.png'),
  },
};

export function TabBar(props: { value: AppTab; bottomInset: number; onChange: (tab: AppTab) => void }) {
  const safeBottom = Math.max(8, props.bottomInset);

  return (
    <View style={[styles.tabBar, { minHeight: 49 + safeBottom, paddingBottom: safeBottom }]}>
      {tabs.map(tab => (
        <Pressable
          key={tab.value}
          accessibilityRole="tab"
          accessibilityState={{ selected: props.value === tab.value }}
          style={({ pressed }) => [
            styles.tabButton,
            props.value === tab.value && styles.tabButtonActive,
            pressed && styles.tabButtonPressed,
          ]}
          onPress={() => props.onChange(tab.value)}
        >
          <View style={styles.tabIconBox}>
            <Image
              source={props.value === tab.value ? tabIcons[tab.value].active : tabIcons[tab.value].inactive}
              style={styles.tabIconImage}
              resizeMode="contain"
            />
          </View>
          <Text style={[styles.tabText, props.value === tab.value && styles.tabTextActive]}>{tab.label}</Text>
        </Pressable>
      ))}
    </View>
  );
}
