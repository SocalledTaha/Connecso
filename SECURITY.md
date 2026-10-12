# Security

- Do not commit subscription URLs, credentials, recovery secrets, private keys, signing keys, or production configuration.
- Redact UUIDs, passwords, tokens, and full subscription URLs from every log path.
- Keep recovery routes on a strict control-plane allowlist. Embedded credentials are extractable and must be low-privilege, rate-limited, and rotatable.
- Verify signed recovery manifests against a pinned public key before atomic replacement. Never bundle a private signing key.
- Never collect device GPS or display the user's physical origin on the map.
- Do not enable Android cleartext traffic for production.
- Release signing secrets belong in GitHub Actions secrets, never in the repository.
