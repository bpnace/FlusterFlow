#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/WhisperFlow.xcodeproj"
SCHEME="WhisperFlow"
DERIVED_DATA="${FLUSTERFLOW_SMOKE_DERIVED_DATA:-/tmp/FlusterFlowProductSmokeDerivedData}"
AUDIO_FILE=""
GENERATED_AUDIO_FILE=""
SMOKE_XCTESTRUN=""
SMOKE_RESULT=""
SMOKE_ARTIFACT_ROOT=""
SMOKE_TEST_NAMES=(
  "testInstalledWhisperTurboStreamsAndFinalizesAudioWhenExplicitlyRequested"
  "testInstalledWhisperLargeFinalizesAudioWhenExplicitlyRequested"
  "testInstalledAdaptiveWhisperRunsTheProductASRPathWhenExplicitlyRequested"
)

cleanup() {
  if [ -n "$GENERATED_AUDIO_FILE" ]; then
    rm -f "$GENERATED_AUDIO_FILE"
  fi
  if [ -n "$SMOKE_XCTESTRUN" ]; then
    rm -f "$SMOKE_XCTESTRUN"
  fi
  if [ -n "$SMOKE_RESULT" ]; then
    rm -f "$SMOKE_RESULT"
  fi
  if [ -n "$SMOKE_ARTIFACT_ROOT" ] && [ -d "$SMOKE_ARTIFACT_ROOT" ]; then
    case "$SMOKE_ARTIFACT_ROOT" in
      /tmp/flusterflow-product-asr-artifacts.*)
        rm -rf "$SMOKE_ARTIFACT_ROOT"
        ;;
    esac
  fi
}
trap cleanup EXIT

product_asr_smoke_passed() {
  local result_file="$1"
  local test_name="$2"

  if awk -v test="$test_name" '
    index($0, test) > 0 {
      line = tolower($0)
      if (line ~ /(skip|skipped|not[ -]?run|not executed)/) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$result_file"; then
    return 1
  fi

  awk -v test="$test_name" '
    index($0, test) > 0 {
      line = tolower($0)
      if (line ~ /(passed|succeeded)/) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$result_file"
}

absolute_audio_path() {
  local input_path="$1"
  local input_directory

  input_directory="$(cd "$(dirname "$input_path")" && pwd -P)"
  printf '%s/%s\n' "$input_directory" "$(basename "$input_path")"
}

if [ "${FLUSTERFLOW_PRODUCT_ASR_ACCEPTANCE_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [local-audio-file]" >&2
  exit 64
fi

# A local, disposable German fixture exercises normalization, the same-session
# streaming/finalization lifecycle, both installed Whisper recognizers, and the
# adaptive product router without storing user audio or text.
if [ "$#" -eq 1 ]; then
  if [ ! -f "$1" ]; then
    echo "Installed-model recognizer acceptance failed: local audio file missing." >&2
    exit 66
  fi
  AUDIO_FILE="$(absolute_audio_path "$1")"
else
  GENERATED_AUDIO_FILE="$(mktemp /tmp/flusterflow-product-asr.XXXXXX.aiff)"
  AUDIO_FILE="$GENERATED_AUDIO_FILE"
  /usr/bin/say -v Anna -r 180 -o "$AUDIO_FILE" "Das ist ein Test."
fi

/usr/bin/xcodebuild -quiet \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -testPlan WhisperFlow-Full \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  build-for-testing

XCTESTRUN="$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
if [ -z "$XCTESTRUN" ]; then
  echo "Installed-model recognizer acceptance failed: xctestrun artifact missing." >&2
  exit 1
fi

SMOKE_XCTESTRUN="${XCTESTRUN%.xctestrun}-product-asr.xctestrun"
/bin/cp "$XCTESTRUN" "$SMOKE_XCTESTRUN"
if ! /usr/libexec/PlistBuddy \
  -c "Set :TestConfigurations:0:TestTargets:0:EnvironmentVariables:FLUSTERFLOW_WHISPER_SMOKE_AUDIO $AUDIO_FILE" \
  "$SMOKE_XCTESTRUN" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy \
    -c "Add :TestConfigurations:0:TestTargets:0:EnvironmentVariables:FLUSTERFLOW_WHISPER_SMOKE_AUDIO string $AUDIO_FILE" \
    "$SMOKE_XCTESTRUN"
fi

SMOKE_RESULT="$(mktemp /tmp/flusterflow-product-asr-result.XXXXXX)"
SMOKE_ARTIFACT_ROOT="$(mktemp -d /tmp/flusterflow-product-asr-artifacts.XXXXXX)"
ONLY_TESTING_ARGUMENTS=()
for test_name in "${SMOKE_TEST_NAMES[@]}"; do
  ONLY_TESTING_ARGUMENTS+=(
    "-only-testing:WhisperFlowTests/WhisperKitRecognizerTests/$test_name"
  )
done
/usr/bin/xcodebuild \
  -xctestrun "$SMOKE_XCTESTRUN" \
  -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$SMOKE_ARTIFACT_ROOT/result.xcresult" \
  "${ONLY_TESTING_ARGUMENTS[@]}" \
  test-without-building | tee "$SMOKE_RESULT"

for test_name in "${SMOKE_TEST_NAMES[@]}"; do
  if ! product_asr_smoke_passed "$SMOKE_RESULT" "$test_name"; then
    echo "Installed-model recognizer acceptance failed: $test_name did not execute successfully." >&2
    exit 1
  fi
done

echo "FlusterFlow installed-model recognizer acceptance: PASS"
