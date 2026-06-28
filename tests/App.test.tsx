/**
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import App from '../App';

jest.mock('@react-native-async-storage/async-storage', () => ({
  getItem: jest.fn(() => Promise.resolve(null)),
  setItem: jest.fn(() => Promise.resolve()),
  removeItem: jest.fn(() => Promise.resolve()),
  getMany: jest.fn(() => Promise.resolve({})),
  setMany: jest.fn(() => Promise.resolve()),
}));

jest.mock('react-native-keychain', () => ({
  ACCESSIBLE: {
    AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY: 'AccessibleAfterFirstUnlockThisDeviceOnly',
  },
  getGenericPassword: jest.fn(() => Promise.resolve(false)),
  setGenericPassword: jest.fn(() => Promise.resolve(true)),
}));

jest.mock('react-native-get-random-values', () => undefined);

jest.mock('react-native-image-picker', () => ({
  launchImageLibrary: jest.fn(() => Promise.resolve({ didCancel: true })),
}));

jest.mock('@react-native-documents/picker', () => ({
  errorCodes: { OPERATION_CANCELED: 'OPERATION_CANCELED' },
  isErrorWithCode: jest.fn((error: unknown) => Boolean(error && typeof error === 'object' && 'code' in error)),
  pick: jest.fn(() => Promise.resolve([])),
  types: {
    images: 'image/*',
    json: 'application/json',
    pdf: 'application/pdf',
    plainText: 'text/plain',
  },
}));

test('renders correctly', async () => {
  Object.defineProperty(globalThis, 'crypto', {
    configurable: true,
    value: {
      getRandomValues: (array: Uint8Array) => {
        array.fill(7);
        return array;
      },
    },
  });

  await ReactTestRenderer.act(() => {
    ReactTestRenderer.create(<App />);
  });
});
