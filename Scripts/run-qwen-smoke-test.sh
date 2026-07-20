#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: run-qwen-smoke-test.sh <local-audio-file>" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

AUDIO_PATH="$1"
if [ ! -r "$AUDIO_PATH" ]; then
  printf '%s\n' "The Qwen smoke-test audio file is not readable." >&2
  exit 66
fi

swift test list >/dev/null
BIN_PATH="$(swift build --show-bin-path)"
TEST_EXECUTABLE_DIRECTORY="$BIN_PATH/WhisperFlowPackageTests.xctest/Contents/MacOS"
if [ ! -d "$TEST_EXECUTABLE_DIRECTORY" ]; then
  printf '%s\n' "The SwiftPM test bundle was not produced." >&2
  exit 70
fi

Scripts/embed-mlx-metallib.sh "$TEST_EXECUTABLE_DIRECTORY/mlx.metallib"

FLUSTERFLOW_QWEN_SMOKE_AUDIO="$AUDIO_PATH" \
  swift test --skip-build \
    --filter 'WhisperFlowTests.Qwen3ASRRecognizerTests/testInstalledQwenModelTranscribesAudioWhenExplicitlyRequested'
