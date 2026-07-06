export default {
  preset: 'react-native',
  setupFiles: ['<rootDir>/jest.setup.js'],
  transformIgnorePatterns: [
    'node_modules/(?!\\.pnpm|((jest-)?react-native|@react-native(-community)?)/)',
    'node_modules/.pnpm/(?!(react-native|@react-native\\+|@react-native-community\\+))',
  ],
};
