# Optimizer release and analytics deployment preflight

This preparation keeps live authorization, signing, installation, and collector hosting outside unattended work. It validates repository structure and offline contracts without reading Keychain items, environment secrets, provider credentials, report contents, or making network requests.

Run the read-only preflight:

```sh
python3 scripts/optimizer-preflight.py --root "$PWD"
```

Add `--strict` in release automation when missing required source, runtime, plugin distribution, MCP, schema, or deployment assets should fail the job. A missing release binary remains `missing_optional` during source preparation; the release packager should build it before signing. Docker is reported as available/unavailable and untested because this preflight never pulls or builds images.

The report separates blockers from these user-controlled steps:

- authorize an explicit live Optimizer session through the normal presence flow;
- sign, notarize, access signing/Keychain material, and install the release build;
- choose collector hosting and a real domain, provision TLS and a private persistent volume, and configure the client endpoint in a later reviewed change.

The endpoint must remain unset until that hosting decision is complete. No placeholder domain from documentation should enter application configuration.

Validate the collector offline:

```sh
python3 Analytics/test_collector.py
python3 Analytics/test_deployment.py
python3 Analytics/validate_deployment.py
```

The validator checks the non-root container, private volume, internal network, TLS-domain gate, exclusion of HTTP access and proxy-error request logs, header/body caps and request deadlines, content-free healthcheck, and a temporary empty SQLite database. It does not prove that a target host, DNS, TLS issuance, firewall, backups, restore procedure, image supply chain, or sustained public-load behavior is correct. Those remain deployment gates.

On the chosen host, review and pin image digests, validate Compose with the real domain supplied out of band, build locally, verify the healthcheck, test backup/restore in an isolated volume, and only then configure the app endpoint. Do not use a live analytics report as a health probe.
