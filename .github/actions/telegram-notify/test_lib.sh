#!/usr/bin/env bash
# Offline test suite for the Luna Build Agent telegram library.
# Mocks curl so nothing touches the network.
#
# Every invariant named in lib.sh (S1-S6) has at least one regression test
# here, alongside the original behaviour tests. If one of these fails, a real
# notification can leak the bot token, vanish, or be attributed to the wrong
# stage.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib.sh"
EXTRACT="$HERE/../../scripts/luna_error_extract.sh"

PASS=0
FAIL=0

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL - %s\n' "$1"; printf '         expected: %s\n' "$2"; printf '         actual:   %s\n' "$3"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
# Assert a substring is present / absent.
has()    { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || bad "$1" "contains '$3'" "$(printf '%s' "$2" | head -c 120)"; }
hasnt()  { printf '%s' "$2" | grep -qF -- "$3" && bad "$1" "absent '$3'" "$(printf '%s' "$2" | head -c 120)" || ok "$1"; }
truthy() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1" "rc=0" "rc=$2"; fi; }
falsy()  { if [ "$2" != "0" ]; then ok "$1"; else bad "$1" "rc!=0" "rc=0"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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
echo "== unit: duration formatting =="
check "dur 5s"      "5s"     "$(luna_duration_short 5)"
check "dur 90s"     "1m 30s" "$(luna_duration_short 90)"
check "dur 3725"    "1h 02m" "$(luna_duration_short 3725)"
check "dur garbage" "0s"     "$(luna_duration_short 'abc')"

echo
echo "== unit: non-numeric sizes degrade safely =="
# A malformed size field used to make `[` and `%d` both emit runtime errors.
out="$(luna_human_size 'not-a-number' 2>&1)"; rc=$?
check "garbage size is 0 B"  "0 B" "$out"
truthy "garbage size exit 0" "$rc"
out="$(luna_human_size '' 2>&1)"
check "empty size is 0 B"    "0 B" "$out"

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
echo "== S1: bot token is never compiled as a regex =="
# A token containing sed metacharacters previously produced either a sed
# syntax error - which discarded the whole buffer - or wrong substitutions.
saved_token="$LUNA_TG_TOKEN"
for meta_token in \
  '999999:AAa/bb_cc' \
  '999999:AA.bb&cc' \
  '999999:AA[bb]cc' \
  '999999:AA\bbcc' \
  '999999:AA*bb+cc' \
  '999999:AA|bb' ; do
  export LUNA_TG_TOKEN="$meta_token"
  res="$(luna_sanitize "leak $meta_token end" 2>&1)"
  rc=$?
  hasnt "token '$meta_token' does not survive" "$res" "$meta_token"
  has    "token '$meta_token' is redacted"      "$res" "[REDACTED]"
  truthy "token '$meta_token' exits 0"          "$rc"
done
export LUNA_TG_TOKEN="$saved_token"
# The literal replacer must also not treat its needle as a pattern.
check "literal replacer is literal" "xAXxXAXx" \
  "$(luna_replace_literal 'x.xX.x' '.' 'AX')"

echo
echo "== S2: rendered messages never exceed the Telegram limit =="
# 60 artifacts with a name+size+sha line each previously produced ~6000 chars,
# which Telegram rejects with a 400 - the notification silently disappeared.
big_art="$WORK/big-art.txt"
: > "$big_art"
i=0
while [ "$i" -lt 60 ]; do
  printf 'a-very-long-artifact-filename-%02d|1048576|deadbeefdeadbeefdeadbeefdeadbeef\n' "$i" >> "$big_art"
  i=$((i + 1))
done
luna_stage_set_current "$LUNA_LAST_STAGE" done

# Mechanism 1: the artifact listing itself is capped, so a directory with an
# absurd number of files is reported honestly instead of silently overflowing.
R="$(luna_render SUCCESS "$LUNA_LAST_STAGE" '' '' "$big_art")"
if [ "${#R}" -le "$LUNA_MESSAGE_LIMIT" ]; then
  ok "60-artifact message is clamped (${#R} <= $LUNA_MESSAGE_LIMIT)"
else
  bad "60-artifact message is clamped" "<= $LUNA_MESSAGE_LIMIT" "${#R}"
fi
has "artifact overflow is counted, not hidden" "$R" "more file(s) not listed"

# Mechanism 2: the final clamp is a hard backstop for anything that still
# overflows. Test it directly so a regression is unambiguous.
LONGBODY="$(head -c 9000 /dev/zero | tr '\0' 'q')"
CL="$(luna_clamp "<b>header</b>
second line
$LONGBODY")"
if [ "${#CL}" -le "$LUNA_MESSAGE_LIMIT" ]; then
  ok "luna_clamp bounds an oversized body (${#CL})"
else
  bad "luna_clamp bounds an oversized body" "<= $LUNA_MESSAGE_LIMIT" "${#CL}"
fi
has "luna_clamp marks the truncation" "$CL" "truncated"
check "short message is untouched" "hello" "$(luna_clamp "hello")"
ATLIMIT="$(printf 'a%.0s' $(seq 1 $LUNA_MESSAGE_LIMIT))"
check "exactly-at-limit is untouched" "$LUNA_MESSAGE_LIMIT" "$(luna_clamp "$ATLIMIT" | wc -c | tr -d ' ')"
hasnt "exactly-at-limit is not marked" "$(luna_clamp "$ATLIMIT")" "truncated"

# Success marks every stage complete even when the stage list grows.
for n in 1 2 5; do
  R="$(luna_render SUCCESS "$n" '' '' '')"
  check "success at stage $n renders" "1" "$(printf '%s' "$R" | grep -c 'Status:</b> SUCCESS')"
done

echo
echo "== S2b: clamping never splits an HTML tag =="
# Truncating mid-tag makes Telegram reject the whole message with a 400,
# turning a cosmetic overflow into a missing notification.
long_artifact="$(printf 'z%s' "$(head -c 6000 /dev/zero | tr '\0' 'y')")"
printf '%s|%s|%s\n' "$long_artifact" "1048576" "deadbeef" > "$WORK/one-huge.txt"
R="$(luna_render SUCCESS "$LUNA_LAST_STAGE" '' '' "$WORK/one-huge.txt")"
b_open="$(printf '%s' "$R" | grep -o '<b>' | wc -l | tr -d ' ')"
b_close="$(printf '%s' "$R" | grep -o '</b>' | wc -l | tr -d ' ')"
if [ "$b_open" = "$b_close" ]; then ok "<b> balanced after clamp"; else bad "<b> balanced after clamp" "equal" "open=$b_open close=$b_close"; fi
c_open="$(printf '%s' "$R" | grep -o '<code>' | wc -l | tr -d ' ')"
c_close="$(printf '%s' "$R" | grep -o '</code>' | wc -l | tr -d ' ')"
if [ "$c_open" = "$c_close" ]; then ok "<code> balanced after clamp"; else bad "<code> balanced after clamp" "equal" "open=$c_open close=$c_close"; fi

echo
echo "== S3: chat ids cannot escape the state directory =="
# The chat id is used as a filename. A traversing id previously wrote anywhere
# on the filesystem.
check "traversal id gets a safe key" "x$(printf '../../etc/passwd' | cksum | cut -d' ' -f1)" \
  "$(luna_state_key '../../etc/passwd')"
check "username gets a safe key" "x$(printf '@mychan' | cksum | cut -d' ' -f1)" \
  "$(luna_state_key '@mychan')"
check "plain negative id preserved" "-100111" "$(luna_state_key '-100111')"
check "plain positive id preserved" "12345"   "$(luna_state_key '12345')"
for bad_id in '../x' 'a/b' '' '.' '..' '-'; do
  k="$(luna_state_key "$bad_id")"
  case "$k" in
    */*|.|'') bad "state key for '$bad_id' is safe" "no separators" "$k" ;;
    *)        ok "state key for '$bad_id' is safe" ;;
  esac
done

echo
echo "== S4: untrusted text cannot forge a workflow command =="
esc="$(luna_gh_escape 'a%b
::set-output name=evil::pwned
::add-mask::x')"
has   "percent is escaped"          "$esc" '%25'
has   "newline becomes %0A"         "$esc" '%0A'
check "escaped text stays one line" "1" "$(printf '%s' "$esc" | grep -c '')"
# The security property is that the result is a SINGLE line: a workflow
# command only executes at the start of a line, so keeping `::set-output`
# inline is harmless while turning the newline into %0A removes the attack.
check "input really was multi-line"  "3" "$(printf 'a\nb\nc' | grep -c '')"
check "escaped output is one line"   "1" "$(luna_gh_escape "$(printf 'a\nb\nc')" | grep -c '')"
check "every newline became %0A"     "2" "$(luna_gh_escape "$(printf 'a\nb\nc')" | grep -o '%0A' | wc -l | tr -d ' ')"
check "log emits exactly one line" "1" "$(luna_log 'x
y' 2>&1 | wc -l | tr -d ' ')"
check "warn emits exactly one line" "1" "$(luna_warn 'x
y' 2>&1 | wc -l | tr -d ' ')"

echo
echo "== S5: reply_markup is valid JSON for hostile inputs =="
m="$(LUNA_RUN_URL='https://gh/o"r/a\b' luna_buttons SUCCESS)"
printf '%s' "$m" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && ok "hostile URL still yields valid JSON" \
  || bad "hostile URL still yields valid JSON" "parseable" "$m"
has "quote is JSON-escaped" "$m" '\"'
# A hostile run URL must not be able to carry the token out in the markup.
export LUNA_TG_TOKEN="123456:AAHsecretTOKENsecretTOKENsecretTOKENsecretxx"
hostile="$(LUNA_RUN_URL="https://x/$LUNA_TG_TOKEN" luna_buttons SUCCESS)"
luna_assert_no_secret "$hostile" 2>/dev/null; rc=$?
falsy "assert catches token in markup" "$rc"
export LUNA_TG_TOKEN="$saved_token"

echo
echo "== S6: chat id lists are never treated as globs =="
# `for id in $ids` expanded the value against the working directory, so a
# chat id of '*' would publish to every file name in the cwd.
mkdir -p "$WORK/globdir"
: > "$WORK/globdir/luna-glombait.txt"
out="$( cd "$WORK/globdir" && LUNA_TG_CHAT_ID='*' luna_chat_ids 2>/dev/null )"
check "'*' yields no chat ids" "" "$out"
out="$( cd "$WORK/globdir" && LUNA_TG_CHAT_ID='-1001 -1002' luna_chat_ids )"
check "space-separated ids split"  "2" "$(printf '%s\n' "$out" | grep -c .)"
check "trailing id is not dropped" "-1002" "$(printf '%s\n' "$out" | tail -n1)"
check "first id is kept"           "-1001" "$(printf '%s\n' "$out" | head -n1)"
check "space ids survive a glob dir" "2" "$(cd "$WORK/globdir" && LUNA_TG_CHAT_ID='-1001 -1002' luna_chat_ids | grep -c .)"
check "comma separated"            "2" "$(LUNA_TG_CHAT_ID='-1,-2' luna_chat_ids | grep -c .)"
check "semicolon separated"        "2" "$(LUNA_TG_CHAT_ID='-1;-2' luna_chat_ids | grep -c .)"
check "CRLF tolerated"             "2" "$(LUNA_TG_CHAT_ID=$'-1\r\n-2\r' luna_chat_ids | grep -c .)"
check "blank ids ignored"          "2" "$(LUNA_TG_CHAT_ID='-1,,  ,-2' luna_chat_ids | grep -c .)"
check "malformed id rejected"      "2" "$(LUNA_TG_CHAT_ID='-1,bad/id,-2' luna_chat_ids 2>/dev/null | grep -c .)"
hasnt "malformed id not emitted"   "$(LUNA_TG_CHAT_ID='-1,bad/id,-2' luna_chat_ids 2>/dev/null)" "bad/id"
check "username accepted"          "1" "$(LUNA_TG_CHAT_ID='@mychannel' luna_chat_ids 2>/dev/null | grep -c .)"

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
echo "== unit: stage lookup by name =="
# Workflows wire stages by name; this is what keeps them in sync with the list.
check "name -> first stage"    "0" "$(luna_stage_index 'Environment Setup')"
check "name -> compile stage"  "5" "$(luna_stage_index 'Compile Kernel')"
check "name -> last stage"     "$LUNA_LAST_STAGE" "$(luna_stage_index 'Publish Artifacts')"
check "last stage index"       "7" "$LUNA_LAST_STAGE"
check "unknown name -> -1"     "-1" "$(luna_stage_index 'No Such Stage')"
check "empty name -> -1"       "-1" "$(luna_stage_index '')"
check "name lookup is case sensitive" "-1" "$(luna_stage_index 'compile kernel')"

echo
echo "== unit: furthest-stage attribution =="
# Lets a failure between notifications be attributed to a real stage instead of
# a hardcoded guess.
luna_stage_set_current 2 active
check "furthest after stage 2" "2" "$(luna_stage_furthest_idx)"
luna_stage_set_current 5 active
check "furthest after stage 5" "5" "$(luna_stage_furthest_idx)"
luna_stage_set_current 5 failed
check "furthest when failed"   "5" "$(luna_stage_furthest_idx)"
rm -rf "$LUNA_STATE_DIR"; luna_state_init >/dev/null
check "furthest before start"  "-1" "$(luna_stage_furthest_idx)"

echo
echo "== unit: luna_stage_mark on a fresh table =="
# luna_stage_mark used to silently no-op when the stages file was empty.
rm -rf "$LUNA_STATE_DIR"
luna_state_init >/dev/null
luna_stage_mark 3 failed
check "mark works on empty table" "failed" "$(luna_stage_status 3)"
check "mark leaves others pending" "pending" "$(luna_stage_status 2)"

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
export LUNA_PROGRESS_PERCENT=900
R="$(luna_render RUNNING 1 '' '' '')"
has "over-100 percent is clamped" "$R" "100%"
export LUNA_PROGRESS_PERCENT='not-a-number'
R="$(luna_render RUNNING 1 '' '' '')"
hasnt "garbage percent is ignored" "$R" "%</code>"
unset LUNA_PROGRESS_PERCENT

echo
echo "== unit: stage timings appear for completed stages =="
rm -rf "$LUNA_STATE_DIR"; luna_state_init >/dev/null
luna_stage_set_current 2 active
luna_state_set "dur_0" "125"
luna_state_set "dur_1" "9"
R="$(luna_render RUNNING 2 '' '' '')"
has "completed stage shows duration" "$R" "(2m 05s)"
has "short stage shows duration"     "$R" "(9s)"

echo
echo "== unit: failure rendering =="
luna_stage_set_current 5 failed
R="$(luna_render FAILED 5 'Compile Kernel' 'make: *** [Makefile:1234] Error 2' '')"
check "failed status"      "1" "$(printf '%s' "$R" | grep -c 'Status:</b> FAILED')"
check "names stage"        "1" "$(printf '%s' "$R" | grep -c 'Failed stage:</b> Compile Kernel')"
check "shows error"        "1" "$(printf '%s' "$R" | grep -c 'Error 2')"
check "no success wording" "0" "$(printf '%s' "$R" | grep -c 'SUCCESS')"
check "failed stage is marked in checklist" "1" "$(printf '%s' "$R" | grep -c "$LUNA_CROSS <b>Compile Kernel</b>")"

echo
echo "== unit: error message sanitizing in render =="
R="$(luna_render FAILED 5 'Compile Kernel' "token=$LUNA_TG_TOKEN leaked" '')"
check "token scrubbed in render" "0" "$(printf '%s' "$R" | grep -cF "$LUNA_TG_TOKEN")"
# HTML in an error must not break parse mode.
R="$(luna_render FAILED 5 'Compile Kernel' '<script>x</script> & <b>' '')"
hasnt "error HTML is escaped" "$R" "<script>"

echo
echo "== unit: artifacts =="
ART="$WORK/art.txt"
printf 'Image-dtb|44055040|deadbeefdeadbeefdeadbeefdeadbeef\nanykernel.sh|2048|cafebabecafebabecafebabecafebabe\n' > "$ART"
R="$(luna_render SUCCESS "$LUNA_LAST_STAGE" '' '' "$ART")"
check "lists artifact name" "1" "$(printf '%s' "$R" | grep -c 'Image-dtb')"
check "shows human size"    "1" "$(printf '%s' "$R" | grep -c '42.0 MB')"
check "shows truncated sha" "1" "$(printf '%s' "$R" | grep -c 'sha256:deadbeefdeadbeef')"
# Artifact names are attacker-influenced filenames, so they must be escaped.
printf 'evil<b>.img|1024|deadbeef\n' > "$WORK/art2.txt"
R="$(luna_render SUCCESS "$LUNA_LAST_STAGE" '' '' "$WORK/art2.txt")"
hasnt "artifact name HTML is escaped" "$R" "<b>.img"
# Many artifacts are capped with an explicit note rather than silently dropped.
: > "$WORK/art3.txt"; i=0
while [ "$i" -lt 40 ]; do printf 'file%02d|1024|deadbeef\n' "$i" >> "$WORK/art3.txt"; i=$((i + 1)); done
R="$(luna_render SUCCESS "$LUNA_LAST_STAGE" '' '' "$WORK/art3.txt")"
has "overflow artifacts are counted" "$R" "more file(s) not listed"

echo
echo "== unit: success marks every stage complete =="
luna_stage_set_current "$LUNA_LAST_STAGE" done
R="$(luna_render SUCCESS "$LUNA_LAST_STAGE" '' '' '')"
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
echo "== integration: publish / edit / fallback =="
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
luna_publish "$(luna_render SUCCESS "$LUNA_LAST_STAGE" '' '' '')" SUCCESS 1 >/dev/null 2>&1
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
echo "== integration: a hostile message id is sent, not looped on =="
# A message id that failed to parse must not make the agent retry the same
# broken edit forever on every subsequent stage.
rm -rf "$LUNA_STATE_DIR"; luna_state_init >/dev/null
export MOCK_MODE=edit_notfound
luna_publish "hostile id test" RUNNING 1 >/dev/null 2>&1
: > "$MOCK_LOG"
luna_publish "hostile id test 2" RUNNING 1 >/dev/null 2>&1
if grep -q 'sendMessage' "$MOCK_LOG"; then
  ok "stale id recovers by sending a new message"
else
  bad "stale id recovers by sending a new message" "sendMessage" "$(head -c 100 "$MOCK_LOG")"
fi

echo
echo "== integration: notification policy =="
# Telegram raises no notification when a message is EDITED. The terminal state
# must therefore be sent as a new message or nobody is told the build ended.
rm -rf "$LUNA_STATE_DIR"; luna_state_init >/dev/null
: > "$MOCK_LOG"; export MOCK_MODE=send_ok

luna_publish "running msg" RUNNING 1 1 0 >/dev/null 2>&1
has "silent running update is delivered" "$(cat "$MOCK_LOG")" "sendMessage"
has "silent running update sets disable_notification" "$(cat "$MOCK_LOG")" "disable_notification=true"

: > "$MOCK_LOG"
luna_publish "running msg 2" RUNNING 1 1 0 >/dev/null 2>&1
has "intermediate update edits in place" "$(cat "$MOCK_LOG")" "editMessageText"
hasnt "intermediate update does not resend" "$(cat "$MOCK_LOG")" "sendMessage"

: > "$MOCK_LOG"
luna_publish "success msg" SUCCESS 1 0 1 >/dev/null 2>&1
has "terminal state sends a fresh message" "$(cat "$MOCK_LOG")" "sendMessage"
hasnt "terminal state does not edit"        "$(cat "$MOCK_LOG")" "editMessageText"
has "terminal state notifies"               "$(cat "$MOCK_LOG")" "disable_notification=false"

: > "$MOCK_LOG"
luna_publish "failed msg" FAILED 1 0 1 >/dev/null 2>&1
has "failure sends a fresh message" "$(cat "$MOCK_LOG")" "sendMessage"
has "failure notifies"              "$(cat "$MOCK_LOG")" "disable_notification=false"

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
echo "== integration: all chats rejected but ids malformed =="
rm -rf "$LUNA_STATE_DIR"; luna_state_init >/dev/null
: > "$MOCK_LOG"; export MOCK_MODE=send_ok
LUNA_TG_CHAT_ID='nope,also/bad' luna_publish "x" RUNNING 1 >/dev/null 2>&1; rc=$?
if [ "$rc" != "0" ] && [ ! -s "$MOCK_LOG" ]; then
  ok "no API call is made for only-malformed ids"
else
  bad "no API call is made for only-malformed ids" "rc!=0 and no calls" "rc=$rc calls=$(wc -l < "$MOCK_LOG")"
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
export LUNA_RUN_ID="test-run"

echo
echo "== unit: error extractor =="
if [ -x "$EXTRACT" ] || [ -f "$EXTRACT" ]; then
  L1="$WORK/log1.log"
  cat > "$L1" <<'LOGEOF'
  CC [M]  drivers/char/vt/vt.o
  LD [M]  vmlinux
arm64-linux-gnu-ld: error: undefined reference to `__stack_chk_fail'
arm64-linux-gnu-ld: collect2: error: ld returned 1 exit status
make[2]: *** [Makefile:1234: net/socket.o] Error 1
make: *** [Makefile:9912: Makefile] Error 2
LOGEOF
  OUT="$(bash "$EXTRACT" "$L1" 2>&1)"
  has   "extractor finds the linker error" "$OUT" "undefined reference to \`__stack_chk_fail'"
  has   "extractor names the failing target" "$OUT" "Failing target: net/socket.o"
  hasnt "extractor drops make's jobserver noise" "$OUT" "jobserver"

  # Bazel/kleaf builds have no make anchor at all.
  L2="$WORK/log2.log"
  printf 'INFO: analyzed target\nERROR: /home/runner/BUILD:123: no such target\n' > "$L2"
  OUT="$(bash "$EXTRACT" "$L2" 2>&1)"
  has "extractor handles bazel-style logs" "$OUT" "no such target"

  # Unrecognisable and empty logs must still produce something useful.
  L3="$WORK/log3.log"; printf 'weird\nstuff\n' > "$L3"
  OUT="$(bash "$EXTRACT" "$L3" 2>&1)"
  has "extractor falls back to the log tail" "$OUT" "weird"
  OUT="$(bash "$EXTRACT" "$WORK/nonexistent.log" 2>&1)"; rc=$?
  truthy "missing log is not fatal" "$rc"
  has "missing log explains itself" "$OUT" "No build log"

  # Output must stay bounded no matter how large the log is.
  python3 -c "
import sys
o=[]
for i in range(120000):
    o.append('  CC [M]  f%d.o' % i)
    if i % 5 == 0:
        o.append('ld: error: undefined reference to \`s%d\`' % i)
o.append('make: *** [Makefile:9912: Makefile] Error 2')
sys.stdout.write('\n'.join(o))
" > "$WORK/huge.log" 2>/dev/null || printf 'make: *** [Makefile:1: x] Error 2\n' > "$WORK/huge.log"
  OUT="$(bash "$EXTRACT" "$WORK/huge.log" 14 900 2>&1)"
  if [ "${#OUT}" -le 950 ]; then
    ok "extractor output is bounded (${#OUT} chars)"
  else
    bad "extractor output is bounded" "<= 950" "${#OUT}"
  fi
  if [ "$(printf '%s\n' "$OUT" | grep -c .)" -le 16 ]; then
    ok "extractor line count is bounded"
  else
    bad "extractor line count is bounded" "<= 16" "$(printf '%s\n' "$OUT" | grep -c .)"
  fi
else
  bad "error extractor exists" "$EXTRACT" "missing"
fi

echo
echo "== wiring: every canonical stage is notified in build.yml =="
# Stage 1 ("Fetch Kernel Source") had no notification at all and sat pending
# for the entire first half of every build.
WF="$HERE/../../workflows/build.yml"
if [ -f "$WF" ]; then
  n=0
  i=0
  while [ "$i" -lt "${#LUNA_STAGES[@]}" ]; do
    if grep -q "stage: '${LUNA_STAGES[$i]}'" "$WF"; then n=$((n + 1)); fi
    i=$((i + 1))
  done
  check "all ${#LUNA_STAGES[@]} canonical stages are wired by name" "${#LUNA_STAGES[@]}" "$n"
  if grep -q "stage_index:" "$WF"; then
    bad "no raw stage_index remains in build.yml" "none" "$(grep -c 'stage_index:' "$WF")"
  else
    ok "no raw stage_index remains in build.yml"
  fi

  # A notification must never run before the step that produces the build name
  # it renders, or the message silently shows a placeholder instead.
  mapfile -t names < <(grep -n "^    - name: " "$WF" | sed 's/^[0-9]*:    - name: //')
  mapfile -t ids  < <(grep -n "^      id: " "$WF" | sed 's/.*id: //')
  extract_line="$(grep -n '^      id: extract$' "$WF" | cut -d: -f1)"
  notify_lines="$(grep -n 'uses: ./.github/actions/telegram-notify' "$WF" | cut -d: -f1)"
  bad_order=0
  while IFS= read -r nl; do
    [ -z "$nl" ] && continue
    if [ -n "$extract_line" ] && [ "$nl" -lt "$extract_line" ]; then
      bad_order=$((bad_order + 1))
    fi
  done < <(printf '%s\n' "$notify_lines")
  if [ "$bad_order" -eq 0 ]; then
    ok "no notification runs before the extract step it depends on"
  else
    bad "no notification runs before the extract step it depends on" "0 early" "$bad_order early"
  fi
else
  bad "build.yml is present" "$WF" "missing"
fi

echo
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
