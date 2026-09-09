# Security and privacy

Do not attach real recordings or private audio to public issues. A minimal synthetic audio fixture, macOS version, device class, and reproduction steps are usually enough.

For a vulnerability that could expose recordings or execute untrusted content, contact the repository owner through a private channel before public disclosure. GitHub private vulnerability reporting should be enabled before the first public release.

The application does not send recordings over the network. Recovery metadata is validated, session paths are generated from identifiers, and source files are checked for symbolic links before export. These controls do not protect against another process already running with the user's full privileges.

Releases must pass signing, notarization, and installation checks. Only the current qualified release will receive security fixes; no production release is qualified yet.
