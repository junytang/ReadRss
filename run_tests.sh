#!/usr/bin/env bash
# Unified test runner for ReadRss HarmonyOS port.
# Runs ArkTS unit tests (via hvigor) and the full-text extraction fixture cases
# (verify.py), which exercise the Python reference of HtmlDom/FullContentFetcher.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEVECO="/Applications/DevEco-Studio.app/Contents"
export DEVECO_SDK_HOME="$DEVECO/sdk"
export NODE_HOME="$DEVECO/tools/node"
export PATH="$NODE_HOME/bin:$PATH"
NODE="$NODE_HOME/bin/node"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw.js"

FAIL=0

echo "========== [1/2] ArkTS unit tests =========="
if [ ! -x "$NODE" ]; then
  echo "SKIP: DevEco node not found at $NODE"
  FAIL=1
else
  RESULT="$ROOT/harmony/entry/.test/default/intermediates/test/coverage_data/test_result.txt"
  rm -f "$RESULT"
  # The daemon can die between runs on this machine; a fresh no-daemon run is
  # slower but makes the result trustworthy.
  (cd "$ROOT/harmony" && "$NODE" "$HVIGOR" --stop-daemon >/dev/null 2>&1 || true)
  (cd "$ROOT/harmony" && "$NODE" "$HVIGOR" --no-daemon --mode module -p product=default \
    -p buildMode=debug test --analyze=normal)
  [ $? -ne 0 ] && FAIL=1
  if [ -f "$RESULT" ]; then
    grep "Tests run:" "$RESULT" || true
    if ! grep -q "Tests run:" "$RESULT" || grep -Eq 'Failure: [1-9]|Error: [1-9]' "$RESULT"; then
      echo "ArkTS unit tests reported failures"
      FAIL=1
    fi
  else
    echo "ArkTS test result file not found: $RESULT"
    FAIL=1
  fi
fi

echo ""
echo "========== [2/2] Full-text extraction fixtures (verify.py) =========="
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not found"
else
  (cd "$ROOT/testcases" && python3 verify.py)
  [ $? -ne 0 ] && FAIL=1
fi

echo ""
if [ $FAIL -ne 0 ]; then
  echo "RESULT: FAILED"
  exit 1
fi
echo "RESULT: ALL PASSED"
exit 0
