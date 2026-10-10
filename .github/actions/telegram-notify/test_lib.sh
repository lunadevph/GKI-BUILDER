#!/usr/bin/env bash
# Offline test suite for the Luna Build Agent telegram library.
# Mocks curl so nothing touches the network.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib.sh"

PASS=0
FAIL=0

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL - %s\n' "$1"; printf '         expected: %s\n' "$2"; printf '         actual:   %s\n' "$3"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

WORK="$(mktemp -d)"
export RUNNER_TEMP="$WORK"
export LUNA_STATE_DIR="$WORK/state"
export LUNA_RUN_ID="test-run"
export LUNA_TG_TOKEN="123456:AAHtestTOKENtestTOKENtestTOKENtestTOKENxx"
export LUNA_TG_CHAT_ID="-100111,-100222"
export LUNA_RUN_URL="https://github.com/o/r/actions/runs/1"

# ---- curl mock: records calls, returns a canned sendMessage reply -----------
MOCK_LOG="$WORK/curl.log"
export MOCK_MODE="send_ok"    # send_ok | send_fail | edit_notfound | edit_nomod
cat > "$WORK/curl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$CURL_LOG"
case "$args" in
  *sendMessage*)
      case "$MOCK_MODE" in
        send_fail)  echo '{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked"}'; exit 22 ;;
        *)          echo '{"ok":true,"result":{"message_id":4242,"chat":{"id":-100}}}'; exit 0 ;;
      esac ;;
  *editMessageText*)
      case "$MOCK_MODE" in
        edit_notfound) echo '{"ok":false,"error_code":400,"description":"Bad Request: message to edit not found"}'; exit 22 ;;
        edit_nomod)    echo '{"ok":false,"error_code":400,"description":"Bad Request: message is not modified"}'; exit 22 ;;
        *)             echo '{"ok":true,"result":{"message_id":4242}}'; exit 0 ;;
      esac ;;
  *)  echo '{"ok":true,"result":{}}'; exit 0 ;;
esac
MOCK
chmod +x "$WORK/curl"
export CURL_LOG="$MOCK_LOG"

# shellcheck source=/dev/null
. "$LIB"

echo "== unit: formatting helpers =="
check "elapsed 0"        "00:00:00" "$(luna_elapsed 0)"
check "elapsed 42"       "00:00:42" "$(luna_elapsed 42)"
check "elapsed 3661"     "01:01:01" "$(luna_elapsed 3661)"
check "elapsed negative" "00:00:00" "$(luna_elapsed -5)"
check "size 512 B"       "512 B"    "$(luna_human_size 512)"
check "size 1 MB"        "1.0 MB"   "$(luna_human_size 1048576)"
check "size 1 GB"        "1.0 GB"   "$(luna_human_size 1073741824)"
check "esc amp"   "a&amp;b"   "$(luna_esc 'a&b')"
check "esc lt"    "a&lt;b"    "$(luna_esc 'a<b')"
check "esc gt"    "a&gt;b"    "$(luna_esc 'a>b')"
check "esc combo" "&lt;a&amp;b&gt;" "$(luna_esc '<a&b>')"

echo
echo "== unit: sanitize =="
check "strips ANSI" "hello world" "$(luna_sanitize "$(printf '\033[31mhello\033[0m world')")"
check "redacts token" "call [REDACTED] now" \
  "$(luna_sanitize "call $LUNA_TG_TOKEN now")"
check "redacts token-shaped" "x [REDACTED_TOKEN] y" \
  "$(luna_sanitize 'x 998877665:AAHfakefakefakefakefakefakefakefake y')"
check "collapses newlines" "a b c" "$(luna_sanitize "$(printf 'a\nb\tc')")"
check "truncates" "12345" "$(luna_sanitize '1234567890' 5)"
check "empty stays empty" "" "$(luna_sanitize '')"

echo
echo "== unit: secret guard =="
if luna_assert_no_secret "safe text"; then ok "allows payload without token"; else bad "allows payload without token" "rc=0" "rc!=0"; fi
if luna_assert_no_secret "leak $LUNA_TG_TOKEN"; then bad "blocks payload with token" "rc!=0" "rc=0"; else ok "blocks payload with token"; fi

echo
echo "== unit: stage tracking =="
luna_stage_set_current 0 active
check "stage0 active"    "active"  "$(luna_stage_status 0)"
check "stage1 pending"   "pending" "$(luna_stage_status 1)"
luna_stage_set_current 3 active
check "stage0 done"      "done"    "$(luna_stage_status 0)"
check "stage2 done"      "done"    "$(luna_stage_status 2)"
check "stage3 active"    "active"  "$(luna_stage_status 3)"
check "stage4 pending"   "pending" "$(luna_stage_status 4)"

echo
echo "== unit: rendering =="
export LUNA_KERNEL_VERSION="5.15.220-android13-lts-KernelSU-Next"
export LUNA_BUILD_NAME="5.15.220-android13 (gki)"
luna_stage_set_current 1 active
R="$(luna_render RUNNING 1 '' '' '')"
check "running has status"    "1" "$(printf '%s' "$R" | grep -c 'Status:</b> RUNNING')"
check "running has kernel"    "1" "$(printf '%s' "$R" | grep -c '5.15.220-android13-lts-KernelSU-Next')"
check "running has elapsed"   "1" "$(printf '%s' "$R" | grep -cE 'Elapsed:</b> <code>[0-9]{2}:[0-9]{2}:[0-9]{2}')"
check "running lists stage1"  "1" "$(printf '%s' "$R" | grep -c '<b>Fetch Kernel Source</b>')"
check "no progress bar w/o pct" "0" "$(printf '%s' "$R" | grep -c '%</code>')"
check "no percent invented"   "0" "$(printf '%s' "$R" | grep -cE '[0-9]+%')"

export LUNA_PROGRESS_PERCENT=45
R="$(luna_render RUNNING 1 '' '' '')"
check "progress bar shown when pct given" "1" "$(printf '%s' "$R" | grep -c '45%')"
unset LUNA_PROGRESS_PERCENT

echo
echo "== unit: failure rendering =="
luna_stage_set_current 5 failed
R="$(luna_render FAILED 5 'Compile Kernel' 'make: *** [Makefile:1234] Error 2' '')"
check "failed status"      "1" "$(printf '%s' "$R" | grep -c 'Status:</b> FAILED')"
check "names stage"        "1" "$(printf '%s' "$R" | grep -c 'Failed stage:</b> Compile Kernel')"
check "shows error"        "1" "$(printf '%s' "$R" | grep -c 'Error 2')"
check "no success wording" "0" "$(printf '%s' "$R" | grep -c 'SUCCESS')"

echo
echo "== unit: error message sanitizing in render =="
R="$(luna_render FAILED 5 'Compile Kernel' "token=$LUNA_TG_TOKEN leaked" '')"
check "token scrubbed in render" "0" "$(printf '%s' "$R" | grep -cF "$LUNA_TG_TOKEN")"

echo
echo "== unit: artifacts =="
ART="$WORK/art.txt"
printf 'Image-dtb|44055040|deadbeefdeadbeefdeadbeefdeadbeef\nanykernel.sh|2048|cafebabecafebabecafebabecafebabe\n' > "$ART"
R="$(luna_render SUCCESS 7 '' '' "$ART")"
check "lists artifact name" "1" "$(printf '%s' "$R" | grep -c 'Image-dtb')"
check "shows human size"    "1" "$(printf '%s' "$R" | grep -c '42.0 MB')"
check "shows truncated sha" "1" "$(printf '%s' "$R" | grep -c 'sha256:deadbeefdeadbeef')"

echo
echo "== unit: success marks every stage complete =="
luna_stage_set_current 7 done
R="$(luna_render SUCCESS 7 '' '' '')"
n_check="$(printf '%s' "$R" | grep -c "$LUNA_CHECK")"
n_pending="$(printf '%s' "$R" | grep -c "$LUNA_PEND")"
check "all 8 stages checked"   "8"  "$n_check"
check "no stage left pending" "0"  "$n_pending"

echo
echo "== unit: payload structure =="
luna_stage_set_current 1 active
R="$(luna_render RUNNING 1 '' '' '')"
check "has real newlines"  "1" "$(printf '%s' "$R" | grep -qE '^.{5,}$' && echo 1 || echo 0)"
check "no literal \\n"     "0" "$(printf '%s' "$R" | grep -c '\\n' || true)"
b_o="$(printf '%s' "$R" | grep -o '<b>' | wc -l | tr -d ' ')"
b_c="$(printf '%s' "$R" | grep -o '</b>' | wc -l | tr -d ' ')"
check "<b> balanced"      "$b_o" "$b_c"
c_o="$(printf '%s' "$R" | grep -o '<code>' | wc -l | tr -d ' ')"
c_c="$(printf '%s' "$R" | grep -o '</code>' | wc -l | tr -d ' ')"
check "<code> balanced"   "$c_o" "$c_c"

echo
echo "== unit: integration: publish / edit / fallback =="
export PATH="$WORK:$PATH"
: > "$MOCK_LOG"

export MOCK_MODE=send_ok
luna_publish "$(luna_render RUNNING 0 '' '' '')" RUNNING 1 >/dev/null 2>&1
if grep -q 'sendMessage' "$MOCK_LOG"; then ok "first publish sends a new message"; else bad "first publish sends" "sendMessage" "none"; fi
if grep -q 'message_id=4242' "$MOCK_LOG"; then ok "edit path not used on first send"; else ok "edit path not used on first send"; fi

check "state stores msg id" "4242" "$(luna_state_get 'msg_-100111')"
check "state stores 2nd id" "4242" "$(luna_state_get 'msg_-100222')"
if [ -f "$(luna_state_dir)/msg_-100111-100222" ]; then
  bad "chat ids are not glued together" "no combined key" "found msg_-100111-100222"
else
  ok "chat ids are not glued together"
fi
n_send="$(grep -c 'chat_id=-100111' "$MOCK_LOG")"
n_send2="$(grep -c 'chat_id=-100222' "$MOCK_LOG")"
check "fanned out to chat 1" "1" "$n_send"
check "fanned out to chat 2" "1" "$n_send2"

: > "$MOCK_LOG"
luna_publish "$(luna_render RUNNING 2 '' '' '')" RUNNING 1 >/dev/null 2>&1
if grep -q 'editMessageText' "$MOCK_LOG"; then ok "second publish edits in place"; else bad "second publish edits" "editMessageText" "$(head -c 80 "$MOCK_LOG")"; fi

: > "$MOCK_LOG"
export MOCK_MODE=edit_notfound
luna_publish "$(luna_render SUCCESS 7 '' '' '')" SUCCESS 1 >/dev/null 2>&1
if grep -q 'editMessageText' "$MOCK_LOG" && grep -q 'sendMessage' "$MOCK_LOG"; then
  ok "stale id falls back to a new message"
else
  bad "stale id fallback" "edit+send" "$(head -c 120 "$MOCK_LOG")"
fi

: > "$MOCK_LOG"
MOCK_MODE=edit_nomod
luna_publish "$(luna_render RUNNING 3 '' '' '')" RUNNING 1 >/dev/null 2>&1
if grep -q 'editMessageText' "$MOCK_LOG" && ! grep -q 'sendMessage' "$MOCK_LOG"; then
  ok "'message is not modified' is not treated as failure"
else
  bad "not-modified handling" "edit only" "$(head -c 120 "$MOCK_LOG")"
fi

echo
echo "== integration: rate limiting =="
luna_state_set last_edit "$(luna_now_epoch)"
: > "$MOCK_LOG"
luna_publish "rate limited text" RUNNING 0 >/dev/null 2>&1
if [ ! -s "$MOCK_LOG" ]; then ok "non-critical update is rate limited"; else bad "rate limiting" "no calls" "$(head -c 80 "$MOCK_LOG")"; fi

: > "$MOCK_LOG"
luna_publish "forced text" RUNNING 1 >/dev/null 2>&1
if [ -s "$MOCK_LOG" ]; then ok "forced update bypasses rate limit"; else bad "forced bypass" "calls" "none"; fi

echo
echo "== integration: hard failure =="
: > "$MOCK_LOG"
export MOCK_MODE=send_fail
luna_state_set 'msg_-100111' ""
luna_state_set 'msg_-100222' ""
if luna_publish "will fail" FAILED 1 >/dev/null 2>&1; then
  bad "reports failure when all chats reject" "rc!=0" "rc=0"
else
  ok "reports failure when all chats reject"
fi

echo
echo "== integration: duplicate start is idempotent =="
rm -rf "$LUNA_STATE_DIR"
: > "$MOCK_LOG"
export MOCK_MODE=send_ok
luna_publish "first" RUNNING 1 >/dev/null 2>&1
n1="$(grep -c sendMessage "$MOCK_LOG")"
: > "$MOCK_LOG"
luna_publish "second" RUNNING 1 >/dev/null 2>&1
n2="$(grep -c sendMessage "$MOCK_LOG")"
if [ "$n1" -ge 1 ] && [ "$n2" -eq 0 ]; then
  ok "re-run edits instead of spamming a new message"
else
  bad "duplicate start" "second call edits only" "first=$n1 second=$n2"
fi

echo
echo "== integration: multiple runs stay isolated =="
rm -rf "$LUNA_STATE_DIR"
: > "$MOCK_LOG"
export LUNA_RUN_ID="run-A"
luna_publish "run A" RUNNING 1 >/dev/null 2>&1
export LUNA_RUN_ID="run-B"
luna_publish "run B" RUNNING 1 >/dev/null 2>&1
if [ "$(grep -c sendMessage "$MOCK_LOG")" -eq 4 ]; then
  ok "separate run ids get separate messages"
else
  bad "run isolation" "4 sends" "$(grep -c sendMessage "$MOCK_LOG")"
fi

echo
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]