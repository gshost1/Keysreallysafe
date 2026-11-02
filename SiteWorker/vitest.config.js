import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Tests run inside workerd (miniflare) against the real site config: the KV
// namespace and rate limiter are local simulations, so the placeholder KV id
// never reaches Cloudflare and nothing touches the network.
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "../wrangler.jsonc" } })],
});
