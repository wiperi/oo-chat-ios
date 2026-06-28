import {
  saveAgentConnection,
  testAgentConnectionForm,
  validateAgentConnectionForm,
  type AgentConnectionConfig,
} from '../src/agent/agentConnectionConfig';

const agentAddress = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

describe('agentConnectionConfig', () => {
  test('rejects invalid agent addresses before saving', () => {
    expect(validateAgentConnectionForm({agentAddress: 'https://example.test'})).toEqual({
      valid: false,
      errors: {
        agentAddress: 'Enter a hosted agent address in 0x-prefixed Ed25519 format.',
      },
    });
  });

  test('test connection returns validation message for invalid input', async () => {
    await expect(testAgentConnectionForm({agentAddress: 'bad'})).resolves.toEqual({
      ok: false,
      message: 'Enter a hosted agent address in 0x-prefixed Ed25519 format.',
    });
  });

  test('saved configuration appears first in the returned agent list', async () => {
    const existing: AgentConnectionConfig[] = [{
      id: 'agent_existing',
      agentAddress: '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      createdAt: 1,
      updatedAt: 1,
    }];

    const configs = await saveAgentConnection(
      {agentAddress},
      existing,
      100,
    );

    expect(configs[0]).toEqual({
      id: 'agent_aaaaaaaa',
      agentAddress,
      createdAt: 100,
      updatedAt: 100,
    });
    expect(configs).toHaveLength(2);
  });
});
