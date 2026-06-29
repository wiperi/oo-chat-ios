import AsyncStorage from '@react-native-async-storage/async-storage';
import {
  deleteConversation,
  listConversations,
  loadActiveConversationId,
  saveActiveConversationId,
  saveConversation,
} from '../src/storage/sessionRepository';
import { deleteAgentSecrets } from '../src/storage/keyManager';
import type { Conversation } from '../src/types';

// Stateful in-memory stand-in for @react-native-async-storage/async-storage (3.x API:
// getItem/setItem/removeItem + getMany/setMany). The store persists across calls so we
// can simulate an app reload after an unexpected interruption.
const mockStore = new Map<string, string>();

jest.mock('@react-native-async-storage/async-storage', () => ({
  getItem: jest.fn(async (key: string) => (mockStore.has(key) ? mockStore.get(key)! : null)),
  setItem: jest.fn(async (key: string, value: string) => {
    mockStore.set(key, value);
  }),
  removeItem: jest.fn(async (key: string) => {
    mockStore.delete(key);
  }),
  getMany: jest.fn(async (keys: string[]) => {
    const result: Record<string, string | null> = {};
    for (const key of keys) {
      result[key] = mockStore.has(key) ? mockStore.get(key)! : null;
    }
    return result;
  }),
  setMany: jest.fn(async (entries: Record<string, string>) => {
    for (const [key, value] of Object.entries(entries)) {
      mockStore.set(key, value);
    }
  }),
}));

jest.mock('../src/storage/keyManager', () => ({
  deleteAgentSecrets: jest.fn(async () => undefined),
}));

// Mirrors the internal storage keys of sessionRepository.ts. Used only to craft a
// corrupted / half-written state on disk (i.e. simulate a crash mid-write).
const CONVERSATION_PREFIX = 'connectonion.mobile.conversation.';

function makeConversation(id: string, overrides: Partial<Conversation> = {}): Conversation {
  const now = Date.now();
  return {
    id,
    title: `Conversation ${id}`,
    agentAddress: '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    createdAt: now,
    updatedAt: now,
    mode: 'safe',
    ulwTurns: null,
    ulwTurnsUsed: null,
    ui: [{ id: `${id}_msg`, type: 'agent', content: 'hello' }],
    ...overrides,
  };
}

describe('sessionRepository', () => {
  beforeEach(() => {
    mockStore.clear();
    jest.clearAllMocks();
  });

  describe('AC1 — messages are persisted as they are sent and received', () => {
    test('persists a conversation with its messages and reads it back', async () => {
      const conversation = makeConversation('a', {
        ui: [
          { id: 'm1', type: 'user', content: 'hi there' },
          { id: 'm2', type: 'agent', content: 'how can I help?' },
        ],
      });

      await saveConversation(conversation);
      const stored = await listConversations();

      expect(stored).toHaveLength(1);
      expect(stored[0].id).toBe('a');
      expect(stored[0].ui).toEqual(conversation.ui);
    });

    test('round-trips every conversation field, including rich chat items and server session', async () => {
      const conversation: Conversation = {
        id: 'rich',
        title: 'Deploy the agent',
        agentAddress: '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        createdAt: 1_000,
        updatedAt: 2_000,
        mode: 'ulw',
        ulwTurns: 5,
        ulwTurnsUsed: 2,
        serverSession: { token: 'srv-123', cursor: 7 },
        ui: [
          { id: 'u1', type: 'user', content: 'build it' },
          { id: 't1', type: 'tool_call', name: 'write_file', args: { path: 'a.ts' }, status: 'done', result: 'ok' },
          { id: 'a1', type: 'agent', content: 'done' },
        ],
      };

      await saveConversation(conversation);
      const [reloaded] = await listConversations();

      expect(reloaded).toEqual(conversation);
    });

    test('appending a message and re-saving overwrites the stored conversation', async () => {
      await saveConversation(makeConversation('a', { ui: [{ id: 'm1', type: 'user', content: 'first' }] }));
      await saveConversation(makeConversation('a', {
        updatedAt: 9_000,
        ui: [
          { id: 'm1', type: 'user', content: 'first' },
          { id: 'm2', type: 'agent', content: 'reply' },
        ],
      }));

      const [stored] = await listConversations();
      expect(stored.ui).toHaveLength(2);
      expect(stored.ui[1]).toEqual({ id: 'm2', type: 'agent', content: 'reply' });
    });
  });

  describe('AC2 — conversations survive an unexpected interruption', () => {
    // sessionRepository is stateless (every call re-reads storage), so reading again with no
    // in-memory state is equivalent to relaunching the app after a crash.
    test('a saved conversation and the active id survive a reload', async () => {
      await saveConversation(makeConversation('a', { ui: [{ id: 'm1', type: 'user', content: 'survive me' }] }));
      await saveActiveConversationId('a');

      const reloaded = await listConversations();
      const activeId = await loadActiveConversationId();

      expect(reloaded.map(item => item.id)).toEqual(['a']);
      expect(reloaded[0].ui[0]).toEqual({ id: 'm1', type: 'user', content: 'survive me' });
      expect(activeId).toBe('a');
    });

    test('a dangling index entry from a half-written save is skipped, not fatal', async () => {
      await saveConversation(makeConversation('a', { updatedAt: 2_000 }));
      await saveConversation(makeConversation('b', { updatedAt: 1_000 }));

      // Simulate a crash that wiped b's row but left b in the index.
      await AsyncStorage.removeItem(`${CONVERSATION_PREFIX}b`);

      const stored = await listConversations();
      expect(stored.map(item => item.id)).toEqual(['a']);
    });
  });

  describe('AC3 — start a new conversation and reopen any previous one', () => {
    test('first launch with empty storage yields no conversations and no active id', async () => {
      expect(await listConversations()).toEqual([]);
      expect(await loadActiveConversationId()).toBeNull();
    });

    test('lists conversations newest-first by updatedAt', async () => {
      await saveConversation(makeConversation('old', { updatedAt: 1_000 }));
      await saveConversation(makeConversation('new', { updatedAt: 3_000 }));
      await saveConversation(makeConversation('mid', { updatedAt: 2_000 }));

      const stored = await listConversations();
      expect(stored.map(item => item.id)).toEqual(['new', 'mid', 'old']);
    });

    test('can reopen any previous conversation by making it active', async () => {
      await saveConversation(makeConversation('old', { updatedAt: 1_000 }));
      await saveConversation(makeConversation('new', { updatedAt: 2_000 }));

      await saveActiveConversationId('old');

      expect(await loadActiveConversationId()).toBe('old');
      const stored = await listConversations();
      expect(stored.find(item => item.id === 'old')).toBeDefined();
    });

    test('switching the active conversation overwrites the previous active id', async () => {
      await saveConversation(makeConversation('a'));
      await saveConversation(makeConversation('b'));

      await saveActiveConversationId('a');
      await saveActiveConversationId('b');

      expect(await loadActiveConversationId()).toBe('b');
    });
  });

  describe('index integrity', () => {
    test('re-saving the same conversation does not create a duplicate index entry', async () => {
      await saveConversation(makeConversation('a', { updatedAt: 1_000 }));
      await saveConversation(makeConversation('a', { updatedAt: 5_000, title: 'renamed' }));

      const stored = await listConversations();
      expect(stored).toHaveLength(1);
      expect(stored[0].title).toBe('renamed');
      expect(stored[0].updatedAt).toBe(5_000);
    });
  });

  describe('deleteConversation', () => {
    test('removes the conversation and clears it when it was the active one', async () => {
      await saveConversation(makeConversation('a'));
      await saveConversation(makeConversation('b'));
      await saveActiveConversationId('a');

      await deleteConversation('a');

      expect((await listConversations()).map(item => item.id)).toEqual(['b']);
      expect(await loadActiveConversationId()).toBeNull();
      expect(deleteAgentSecrets).toHaveBeenCalledWith('0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    });

    test('deleting a non-active conversation leaves the active id intact', async () => {
      await saveConversation(makeConversation('a', { updatedAt: 2_000 }));
      await saveConversation(makeConversation('b', { updatedAt: 1_000 }));
      await saveActiveConversationId('a');

      await deleteConversation('b');

      expect((await listConversations()).map(item => item.id)).toEqual(['a']);
      expect(await loadActiveConversationId()).toBe('a');
    });

    test('deleting an unknown id is a no-op and leaves existing state untouched', async () => {
      await saveConversation(makeConversation('a'));
      await saveActiveConversationId('a');

      await deleteConversation('does-not-exist');

      expect((await listConversations()).map(item => item.id)).toEqual(['a']);
      expect(await loadActiveConversationId()).toBe('a');
    });
  });
});
