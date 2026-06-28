import { isHostedAgentAddress, testAgentConnection, type ConnectionTestResult } from '../session/remoteAgentClient';

export interface AgentConnectionForm {
  agentAddress: string;
}

export interface AgentConnectionConfig {
  id: string;
  agentAddress: string;
  createdAt: number;
  updatedAt: number;
}

export interface AgentConnectionValidation {
  valid: boolean;
  errors: {
    agentAddress?: string;
  };
}

export function validateAgentConnectionForm(form: AgentConnectionForm): AgentConnectionValidation {
  const agentAddress = form.agentAddress.trim();
  if (!isHostedAgentAddress(agentAddress)) {
    return {
      valid: false,
      errors: {
        agentAddress: 'Enter a hosted agent address in 0x-prefixed Ed25519 format.',
      },
    };
  }

  return { valid: true, errors: {} };
}

export async function testAgentConnectionForm(form: AgentConnectionForm): Promise<ConnectionTestResult> {
  const validation = validateAgentConnectionForm(form);
  if (!validation.valid) {
    return {
      ok: false,
      message: validation.errors.agentAddress ?? 'Invalid agent connection.',
    };
  }

  return testAgentConnection(form.agentAddress.trim());
}

export async function saveAgentConnection(
  form: AgentConnectionForm,
  existingConfigs: AgentConnectionConfig[],
  now = Date.now(),
): Promise<AgentConnectionConfig[]> {
  const validation = validateAgentConnectionForm(form);
  if (!validation.valid) {
    throw new Error(validation.errors.agentAddress ?? 'Invalid agent connection.');
  }

  const agentAddress = form.agentAddress.trim();
  const existing = existingConfigs.find(config => config.agentAddress === agentAddress);
  const id = existing?.id ?? `agent_${agentAddress.slice(2, 10)}`;

  const savedConfig: AgentConnectionConfig = {
    id,
    agentAddress,
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
  };

  return [
    savedConfig,
    ...existingConfigs.filter(config => config.id !== id),
  ];
}
