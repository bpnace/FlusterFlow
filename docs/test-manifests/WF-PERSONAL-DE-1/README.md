# WF-PERSONAL-DE-1

`WF-PERSONAL-DE-1` is a local-only German benchmark corpus shape for personal ASR checks.

Tracked files define only the contract. Audio clips, local transcripts, local manifests, and runner outputs live under `docs/test-manifests/WF-PERSONAL-DE-1/private/`, which is gitignored and removable as one directory.

Expected local clip split:

| Category | Count |
| --- | ---: |
| standard | 10 |
| domainTerms | 10 |
| fillerCorrection | 10 |
| noise | 5 |
| whisper | 5 |

Use `private/clips/` for local audio files. Do not commit audio, transcripts, window titles, URLs, or application content.
