import React from 'react';
import { View } from 'react-native';
import { styles } from '../../styles/appStyles';

export function BackChevron() {
  return (
    <View style={styles.backIcon}>
      <View style={styles.backIconLineTop} />
      <View style={styles.backIconLineBottom} />
    </View>
  );
}
