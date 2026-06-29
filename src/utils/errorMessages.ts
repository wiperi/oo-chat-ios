export type ConnectionErrorKind =
  | 'network'
  | 'timeout'
  | 'invalid-endpoint'
  | 'unknown';

export type ErrorAction = 'retry' | 'edit-connection' | 'dismiss';

export interface UserFacingError {
  kind: ConnectionErrorKind;
  title: string;
  message: string;
  actions: ErrorAction[];
}

const ACTION_LABELS: Record<ErrorAction, string> = {
  retry: 'Retry',
  'edit-connection': 'Edit connection',
  dismiss: 'Dismiss',
};

export function actionLabel(action: ErrorAction): string {
  return ACTION_LABELS[action];
}

const COPY: Record<ConnectionErrorKind, Omit<UserFacingError, 'kind'>> = {
  network: {
    title: 'No connection',
    message:
      "We couldn't reach the agent. Check your internet connection, then try again.",
    actions: ['retry', 'edit-connection', 'dismiss'],
  },
  timeout: {
    title: 'This is taking too long',
    message:
      'The agent did not respond in time. It may be busy or offline — give it a moment and try again.',
    actions: ['retry', 'edit-connection', 'dismiss'],
  },
  'invalid-endpoint': {
    title: "Can't reach this agent",
    message:
      'This agent address did not accept the connection. Double-check the address and try again.',
    actions: ['edit-connection', 'retry', 'dismiss'],
  },
  unknown: {
    title: 'Something went wrong',
    message: 'An unexpected problem occurred. Please try again.',
    actions: ['retry', 'dismiss'],
  },
};

function rawText(error: unknown): string {
  if (typeof error === 'string') {
    return error;
  }
  if (error instanceof Error) {
    return error.message;
  }
  if (error && typeof error === 'object' && 'message' in error) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === 'string') {
      return message;
    }
  }
  return '';
}

export function classifyConnectionError(error: unknown): ConnectionErrorKind {
  const text = rawText(error).toLowerCase();
  if (!text) {
    return 'unknown';
  }

  // time out
  if (text.includes('timed out') || text.includes('timeout')) {
    return 'timeout';
  }

  // Bad address, or a handshake the agent never accepted.
  if (
    text.includes('invalid hosted agent address') ||
    text.includes('0x-prefixed') ||
    text.includes('accepted the session')
  ) {
    return 'invalid-endpoint';
  }

  // Host unreachable or the socket dropped.
  if (
    text.includes('could not connect') ||
    text.includes('websocket') ||
    text.includes('network request failed') ||
    text.includes('failed to fetch') ||
    text.includes('network') ||
    text.includes('connection closed')
  ) {
    return 'network';
  }

  return 'unknown';
}

export function toUserFacingError(error: unknown): UserFacingError {
  const kind = classifyConnectionError(error);
  return { kind, ...COPY[kind] };
}

export function invalidAddressError(): UserFacingError {
  return {
    kind: 'invalid-endpoint',
    title: 'Check the agent address',
    message: 'Enter a hosted agent address in 0x-prefixed Ed25519 format.',
    actions: ['edit-connection', 'dismiss'],
  };
}
