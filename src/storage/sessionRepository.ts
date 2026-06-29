import AsyncStorage from '@react-native-async-storage/async-storage';
import type { Conversation } from '../types';

const INDEX_KEY = 'connectonion.mobile.conversations.index';
const ACTIVE_KEY = 'connectonion.mobile.conversations.active';
const CONVERSATION_PREFIX = 'connectonion.mobile.conversation.';

async function readIndex(): Promise<string[]> {
  const raw = await AsyncStorage.getItem(INDEX_KEY);
  return raw ? JSON.parse(raw) : [];
}

async function writeIndex(ids: string[]): Promise<void> {
  await AsyncStorage.setItem(INDEX_KEY, JSON.stringify(Array.from(new Set(ids))));
}

export async function listConversations(): Promise<Conversation[]> {
  const ids = await readIndex();
  const rows = await AsyncStorage.getMany(ids.map(id => CONVERSATION_PREFIX + id));
  return Object.values(rows)
    .map(value => (value ? JSON.parse(value) as Conversation : null))
    .filter((value): value is Conversation => value !== null)
    .sort((a, b) => b.updatedAt - a.updatedAt);
}

export async function saveConversation(conversation: Conversation): Promise<void> {
  const ids = await readIndex();
  await AsyncStorage.setMany({
    [CONVERSATION_PREFIX + conversation.id]: JSON.stringify(conversation),
    [INDEX_KEY]: JSON.stringify(Array.from(new Set([conversation.id, ...ids]))),
  });
}

export async function deleteConversation(id: string): Promise<void> {
  const ids = await readIndex();
  await AsyncStorage.removeItem(CONVERSATION_PREFIX + id);
  await writeIndex(ids.filter(existing => existing !== id));
  const activeId = await loadActiveConversationId();
  if (activeId === id) {
    await AsyncStorage.removeItem(ACTIVE_KEY);
  }
}

export async function loadActiveConversationId(): Promise<string | null> {
  return AsyncStorage.getItem(ACTIVE_KEY);
}

export async function saveActiveConversationId(id: string): Promise<void> {
  await AsyncStorage.setItem(ACTIVE_KEY, id);
}
