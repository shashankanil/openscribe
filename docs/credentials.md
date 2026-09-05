# Provider credentials

Credentials are scoped by purpose (transcription or writing/summary), provider ID, and normalized base URL. Model changes reuse the connection's key. Switching providers, hosts, ports, or API paths selects a different credential. Equivalent URL capitalization for scheme/host, default ports, and trailing slashes resolve to the same connection.

Settings shows saved/missing status without filling the saved secret into the field. Saving a nonempty draft replaces only the selected scope. Removing is an explicit action; an empty draft cannot silently delete a key. Drafts reset when the selected scope changes. Read, save, and remove errors appear inline; saving does not assert that the provider accepted the credential.

Transcription and cleanup may use different credentials even with the same provider. A button explicitly copies the other purpose's saved key only when provider and normalized endpoint both match. The two copies remain independently replaceable and removable.

Existing global credentials migrate once to the currently configured provider/endpoint for their respective purpose. Migration preserves already scoped credentials and retires the global slots in one atomic file replacement. Historical provider keys overwritten by the old app cannot be reconstructed. Recovery jobs and meeting summaries resolve the credential against their saved settings, rather than the provider currently selected in the UI. Secrets are not embedded in notes, meeting records, or recovery settings.

Storage remains the existing local credentials.json file under Application Support/WhisperFlow, with directory permissions 0700 and file permissions 0600. This is not Keychain or encrypted storage. The endpoint portion of account identifiers is SHA-256 hashed; the credential values remain in the permission-restricted JSON file.

Tests cover provider/purpose/endpoint isolation, canonical URLs, one-time migration, existing scoped keys, deletion without resurrection, corruption and failure reporting, and filesystem permissions.
