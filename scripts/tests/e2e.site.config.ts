import type { E2EConfig } from 'e2e';
import { web } from '@e2e-dev/web';
export default {
  workers: 1, tests: ['site.e2e.ts'],
  targets: [{ name: 'marketing', engine: web(), app: {
    url: 'http://127.0.0.1:0',
    command: { executable: 'node', args: ['site_fixture.cjs'], env: { KEYS_FIXTURE_PORT: '{port}' } },
  } }],
} satisfies E2EConfig;
