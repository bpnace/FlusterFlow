# Contributing to FlusterFlow

Thank you for helping improve FlusterFlow. Contributions should preserve the product's local-first privacy boundary, predictable insertion behavior, and native macOS experience.

## Before starting

For substantial changes, open an issue first so the scope, privacy impact, and verification plan can be discussed. Keep pull requests focused and avoid unrelated refactoring.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).

## Development requirements

- macOS 15 or newer
- Apple Silicon for the documented build and test path
- Xcode with Swift 6
- `jq`
- Xcode Metal Toolchain for the app build (`xcodebuild -downloadComponent MetalToolchain`)

Before pushing, build the unsigned app and run the full app test plan locally:

```bash
bash Scripts/run-capped-tests.sh --full
```

GitHub CI runs the standalone verification tool tests, repository hygiene,
privacy checks, and artifact checks. To run the latter checks locally:

```bash
bash Scripts/verify-repository-hygiene.sh --history
bash Scripts/test-verified-artifact-chain.sh
bash Scripts/verify-target-harness.sh
bash Scripts/verify-local-privacy.sh
```

Before tagging a release, run **Release verification** on `main` with the
current full commit SHA. The workflow builds the app with GitHub's Xcode
toolchain and runs the capped app tests. Check that both CI and Release
verification passed for the commit you intend to tag.

```bash
release_commit="$(gh api repos/{owner}/{repo}/commits/main --jq .sha)"
gh workflow run release-verification.yml --ref main -f commit="$release_commit"
```

## Privacy and repository hygiene

Never commit:

- real recordings, transcripts, prompts, cursor context, window titles, URLs, or personal lexicon contents;
- API keys, credentials, signing identities, certificates, provisioning profiles, or keychains;
- local usernames, absolute workstation paths, device names, account identifiers, or personal contact data;
- model weights, generated caches, application bundles, archives, test results, logs, or local agent state.

Use synthetic fixtures and reserved example domains. Test secrets must be obvious canaries and must never be usable credentials.

Before opening a pull request, run:

```bash
bash Scripts/verify-repository-hygiene.sh
bash Scripts/verify-repository-hygiene.sh --history
```

If sensitive material was ever committed, removing it in a later commit is not sufficient. Stop and coordinate a history rewrite and credential rotation before publication.

## Pull-request expectations

A pull request should include:

- the user-facing intent and affected components;
- privacy, security, network, persistence, and Accessibility impact;
- tests added or updated;
- the exact verification commands run and their results;
- known limitations and any manual macOS or TCC checks still required.

Changes involving microphone capture, recording history, cloud rewrite, model provisioning, Accessibility insertion, signing, installation, or deletion behavior require explicit regression coverage.

## Commit messages

Use an imperative first line that explains the intent. Optional trailers may document constraints, rejected alternatives, risk, and completed verification.

## Security reports

Do not report vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md).
