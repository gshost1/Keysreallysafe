import type { E2EConfig } from 'e2e';
import { web } from '@e2e-dev/web';
export default {
  workers: 1,
  tests: ['dashboard.e2e.ts'],
  targets: [{ name: 'dashboard', engine: web(), app: {
    url: 'http://127.0.0.1:0',
    command: { executable: 'node', args: ['test_keys_dashboard_ui.cjs'], env: { KEYS_FIXTURE_PORT: '{port}' } },
  } }],
} satisfies E2EConfig;
