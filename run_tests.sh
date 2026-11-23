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
  (cd "$ROOT/harmony" && "$NODE" "$HVIGOR" --mode module -p product=default \
    -p buildMode=debug test --analyze=normal)
  [ $? -ne 0 ] && FAIL=1
  RESULT="$ROOT/harmony/entry/.test/default/intermediates/test/coverage_data/test_result.txt"
  if [ -f "$RESULT" ]; then
    grep "Tests run:" "$RESULT" || true
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
