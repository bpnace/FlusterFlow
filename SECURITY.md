# Security Policy

## Supported versions

FlusterFlow is currently developed on the latest commit of the default branch. Release candidates and older source snapshots do not receive separate security fixes.

| Version | Supported |
| --- | --- |
| Latest default branch | Yes |
| Older commits and release candidates | No |

## Reporting a vulnerability

Please do not disclose suspected vulnerabilities in a public issue, pull request, discussion, log, screenshot, or test fixture.

Use GitHub's private vulnerability reporting from the repository's **Security** tab and choose **Report a vulnerability**. Include only the information required to reproduce and assess the issue:

- the affected commit or version;
- the impacted macOS version and hardware class;
- a concise description of the security or privacy impact;
- minimal reproduction steps;
- whether microphone data, transcripts, cursor context, API keys, Accessibility access, or local recordings may be exposed.

Do not include real recordings, transcripts, API keys, personal data, production credentials, or unrelated system logs. Use synthetic data and redact account names and local paths.

If private vulnerability reporting is temporarily unavailable, do not publish the details. Open a minimal public issue stating that a private reporting channel is required, without vulnerability details.

## Security boundaries

Reports are especially useful when they concern:

- unintended microphone capture or retention;
- transcript, cursor-context, or recording disclosure;
- OpenAI API-key handling or accidental logging;
- network requests outside the documented model-provisioning and optional cloud-rewrite paths;
- insertion into secure or unintended Accessibility targets;
- bypasses of local-only history retry;
- unsafe model or dependency provenance;
- signing, installation, update, or artifact-integrity failures.

The expected privacy and security contracts are documented in:

- [Privacy data flow](docs/privacy-data-flow.md)
- [Threat model](docs/threat-model.md)
- [Model supply chain](docs/model-supply-chain.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## Disclosure process

A report will be assessed before public discussion. Once a fix and release plan are available, maintainers may coordinate a GitHub Security Advisory and public disclosure. No embargo or response deadline is promised until it has been explicitly agreed with the reporter.
