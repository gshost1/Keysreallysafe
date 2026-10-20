import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Tests run inside workerd (miniflare) with a throwaway secret; nothing
// reaches the network or a real Cloudflare account.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          RELAY_SECRET: "ksfr_test_secret_for_offline_tests_only",
          // Shorter than production so the timeout tests finish quickly.
          RELAY_UPLOAD_TIMEOUT_MS: "400",
          RELAY_HEAD_TIMEOUT_MS: "400",
          RELAY_IDLE_TIMEOUT_MS: "400",
        },
      },
    }),
  ],
});
