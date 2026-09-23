-- One row per Mac a license is active on. install_id is a random UUID the app
-- keeps in that Mac's Keychain (this-device-only); model is the hardware model
-- identifier (e.g. Mac15,6), shown on the buyer's license page.
CREATE TABLE activations (
  license_id TEXT NOT NULL,
  install_id TEXT NOT NULL,
  model TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  PRIMARY KEY (license_id, install_id)
);

-- A revoked license activates nowhere and stops at each Mac's next check-in.
CREATE TABLE revoked (
  license_id TEXT PRIMARY KEY,
  reason TEXT NOT NULL,
  revoked_at INTEGER NOT NULL
);
