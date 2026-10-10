#!/usr/bin/env bash
# Luna Build Agent - shared helpers for the telegram-notify composite action.
#
# Design notes:
#   * All state lives in a directory of tiny flat files, so no JSON parser is
#     required and concurrent stages of the same job cannot corrupt a document.
#   * State is keyed by run id, so a re-run never mixes status with an old one.
#   * Every outbound value is HTML-escaped and secret-scrubbed before it can
#     reach the API, so a build log line can never leak the bot token.
#   * Telegram is edited in place (editMessageText) rather than re-sent, and
#     edits are rate limited so a fast pipeline cannot trip API limits.

set -uo pipefail

# ---------------------------------------------------------------- constants --

# Canonical pipeline. Every stage here maps to real steps in build.yml.
# Order matters: the rendered checklist follows this list.
LUNA_STAGES=(
  "Environment Setup"
  "Fetch Kernel Source"
  "Apply Patches"
  "Prepare Toolchain"
  "Configure Kernel"
  "Compile Kernel"
  "Verify Artifacts"
  "Publish Artifacts"
)

LUNA_RULE="—"                 # em dash rule
LUNA_MOON="🌙"                 # moon face
LUNA_PENGUIN="🐧"              # linux penguin
LUNA_CLOCK="🕒"                # clock face
LUNA_STOPWATCH="⏱"            # stopwatch
LUNA_DOWN="📥"                 # inbox / fetch
LUNA_CHECK="✅"                # check mark
LUNA_SPIN="🔄"                 # arrows / active
LUNA_PEND="⏳"                 # hourglass / pending
LUNA_CROSS="❌"                # cross mark
LUNA_BOOM="🚨"                 # rotating light / failed
LUNA_FOLDER="📁"               # folder / artifacts
LUNA_FLOPPY="💾"               # floppy / artifact
LUNA_GEAR="⚙"                 # gear
LUNA_TAG="🏷"                  # tag
LUNA_MAG="🔍"                  # magnifier / logs
LUNA_ROCKET="🚀"               # rocket
LUNA_KEY="🔑"                  # key
LUNA_BOLT="⚡"                  # high voltage / compiling

LUNA_STAGE_MAX_EDIT_INTERVAL="${LUNA_STAGE_MAX_EDIT_INTERVAL:-20}"

# ------------------------------------------------------------------ helpers --

luna_log() { printf '::notice::%s\n' "$*" >&2; }
luna_warn() { printf '::warning::%s\n' "$*" >&2; }
luna_err()  { printf '::error::%s\n' "$*" >&2; }

luna_now_epoch() { date -u '+%s'; }

luna_utc_human() {
  # 2026-10-10T12:02:50Z -> "2026-10-10 12:02:50 UTC"
  date -u -d "@${1:-$(luna_now_epoch)}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
    || date -u '+%Y-%m-%d %H:%M:%S UTC'
}

luna_elapsed() {
  # Seconds -> HH:MM:SS
  local s=${1:-0}
  [ "$s" -lt 0 ] && s=0
  printf '%02d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

luna_human_size() {
  # Bytes -> compact size. Falls back to raw bytes when unknown.
  local b=${1:-0}
  if   [ "$b" -ge 1073741824 ] 2>/dev/null; then printf '%d.%d GB' $((b / 1073741824)) $(((b % 1073741824) * 10 / 1073741824))
  elif [ "$b" -ge 1048576 ]    2>/dev/null; then printf '%d.%d MB' $((b / 1048576))    $(((b % 1048576) * 10 / 1048576))
  elif [ "$b" -ge 1024 ]       2>/dev/null; then printf '%d.%d KB' $((b / 1024))       $(((b % 1024) * 10 / 1024))
  else printf '%d B' "$b"; fi
}

# Escape for Telegram HTML parse mode. Applied to every interpolated value.
luna_esc() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Strip ANSI escapes, redact the bot token and anything token-shaped, collapse
# whitespace, and hard-truncate. Used on any log-derived text.
luna_sanitize() {
  local text="$1" limit="${2:-600}"
  [ -z "$text" ] && { printf ''; return 0; }

  # Remove CSI colour sequences.
  text="$(printf '%s' "$text" | sed -e 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' -e 's/\r//g')"

  # Redact the real token if present.
  if [ -n "${LUNA_TG_TOKEN:-}" ]; then
    text="$(printf '%s' "$text" | sed -e "s/${LUNA_TG_TOKEN}/[REDACTED]/g")"
  fi
  # Redact anything that structurally looks like a bot token.
  text="$(printf '%s' "$text" | sed -E 's/[0-9]{6,12}:[A-Za-z0-9_-]{30,}/[REDACTED_TOKEN]/g')"

  # Collapse to a single line so Telegram markup stays predictable.
  text="$(printf '%s' "$text" | tr '\n\t' '  ' | tr -s ' ')"

  # Trim to the limit.
  printf '%s' "$text" | cut -c1-"$limit"
}

# Hard guarantee that the rendered payload cannot contain the token.
luna_assert_no_secret() {
  local payload="$1"
  [ -z "${LUNA_TG_TOKEN:-}" ] && return 0
  case "$payload" in
    *"${LUNA_TG_TOKEN}"*)
      luna_err "Refusing to send: rendered message contains the bot token."
      return 1
      ;;
  esac
  return 0
}

# -------------------------------------------------------------------- state --

luna_state_dir() {
  local base="${LUNA_STATE_DIR:-${RUNNER_TEMP:-/tmp}}"
  printf '%s/luna-agent-%s' "$base" "${LUNA_RUN_ID:-local}"
}

luna_state_init() {
  local d; d="$(luna_state_dir)"
  mkdir -p "$d" 2>/dev/null || return 1
  if [ ! -f "$d/started" ]; then
    luna_now_epoch > "$d/started"
    : > "$d/stages"
    : > "$d/final"
  fi
  printf '%s' "$d"
}

luna_state_get() {
  local d; d="$(luna_state_dir)"
  [ -f "$d/$1" ] && cat "$d/$1" || printf ''
}

luna_state_set() {
  local d; d="$(luna_state_dir)"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$2" > "$d/$1"
}

luna_started_epoch() {
  local v; v="$(luna_state_get started)"
  case "$v" in ''|*[!0-9]*) luna_now_epoch ;; *) printf '%s' "$v" ;; esac
}

# -------------------------------------------------------------- stage table --
# stages file format:  <index> <TAB> <status>      status in done|active|failed
# Rendering walks LUNA_STAGES and looks each one up here.

luna_stage_mark() {
  local idx="$1" status="$2"
  local d; d="$(luna_state_init)" || return 1
  local tmp="$d/stages.tmp"
  : > "$tmp"
  local i=0 line idx_s line_s
  while IFS=$'\t' read -r idx_s line_s; do
    [ -z "$idx_s" ] && continue
    if [ "$idx_s" = "$idx" ]; then
      printf '%s\t%s\n' "$idx_s" "$status" >> "$tmp"
    else
      printf '%s\t%s\n' "$idx_s" "${line_s:-pending}" >> "$tmp"
    fi
  done < "$d/stages"
  mv "$tmp" "$d/stages"
}

# Mark every stage before `upto` done, `upto` active, rest pending.
luna_stage_set_current() {
  local upto="$1" status="${2:-active}"
  local d; d="$(luna_state_init)" || return 1
  local tmp="$d/stages.tmp"
  : > "$tmp"
  local i s
  for i in "${!LUNA_STAGES[@]}"; do
    if   [ "$i" -lt "$upto" ];   then s="done"
    elif [ "$i" -eq "$upto" ];   then s="$status"
    else                              s="pending"
    fi
    printf '%s\t%s\n' "$i" "$s" >> "$tmp"
  done
  mv "$tmp" "$d/stages"
}

luna_stage_status() {
  local want="$1"
  local d; d="$(luna_state_dir)"
  [ -f "$d/stages" ] || { printf 'pending'; return 0; }
  local idx_s st
  while IFS=$'\t' read -r idx_s st; do
    if [ "$idx_s" = "$want" ]; then printf '%s' "${st:-pending}"; return 0; fi
  done < "$d/stages"
  printf 'pending'
}

# ---------------------------------------------------------------- rendering --

luna_status_label() {
  case "$1" in
    RUNNING)  printf 'RUNNING' ;;
    SUCCESS)  printf 'SUCCESS' ;;
    FAILED)   printf 'FAILED' ;;
    *)        printf 'IDLE' ;;
  esac
}

luna_status_icon() {
  case "$1" in
    RUNNING)  printf '%s' "$LUNA_SPIN" ;;
    SUCCESS)  printf '%s' "$LUNA_CHECK" ;;
    FAILED)   printf '%s' "$LUNA_BOOM" ;;
    *)        printf '%s' "$LUNA_PEND" ;;
  esac
}

# luna_render <status> <stage_index> <failure_stage> <error_summary> <artifact_file>
# Builds the message as an array of lines and joins them with real newlines.
# (String concatenation + `$(printf '...\n')` loses trailing newlines, which
# silently welded every field onto one line.)
luna_render() {
  local status="$1" stage_idx="${2:--1}" fail_stage="${3:-}" fail_msg="${4:-}"
  local artifact_file="${5:-}"

  local started now elapsed
  started="$(luna_started_epoch)"
  now="$(luna_now_epoch)"
  elapsed="$(luna_elapsed $((now - started)))"

  local kernel build
  kernel="$(luna_esc "${LUNA_KERNEL_VERSION:-unknown}")"
  build="$(luna_esc "${LUNA_BUILD_NAME:-build}")"

  local rule_line
  rule_line="${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}${LUNA_RULE}"

  local -a L=()
  L+=("$LUNA_MOON <b>Luna Kernel Build</b>")
  L+=("$rule_line")

  L+=("$LUNA_MOON <b>Status:</b> $(luna_status_label "$status")")
  L+=("")
  L+=("$LUNA_PENGUIN <b>Kernel:</b> <code>$kernel</code>")
  L+=("$LUNA_TAG <b>Build:</b> <code>$build</code>")
  L+=("$LUNA_CLOCK <b>Started:</b> <code>$(luna_esc "$(luna_utc_human "$started")")</code>")
  L+=("$LUNA_STOPWATCH <b>Elapsed:</b> <code>$elapsed</code>")

  # ---- progress bar, only when a real percentage was measured
  if [ -n "${LUNA_PROGRESS_PERCENT:-}" ] && \
     printf '%s' "${LUNA_PROGRESS_PERCENT}" | grep -Eq '^[0-9]+$'; then
    local p="${LUNA_PROGRESS_PERCENT}"
    [ "$p" -gt 100 ] && p=100
    local filled=$(( p * 20 / 100 )) bar='' i=0
    while [ "$i" -lt 20 ]; do
      if [ "$i" -lt "$filled" ]; then bar+="$LUNA_MOON"; else bar+='·'; fi
      i=$((i + 1))
    done
    L+=("")
    L+=("$LUNA_MOON <b>$bar</b> <code>$p%</code>")
  fi

  L+=("")
  L+=("$LUNA_DOWN <b>BUILD PIPELINE</b>")
  local i st icon label
  for i in "${!LUNA_STAGES[@]}"; do
    st="$(luna_stage_status "$i")"
    label="$(luna_esc "${LUNA_STAGES[$i]}")"
    case "$st" in
      done|success) icon="$LUNA_CHECK" ;;
      active)       icon="$LUNA_SPIN" ;;
      failed)       icon="$LUNA_CROSS" ;;
      *)            icon="$LUNA_PEND" ;;
    esac
    if [ "$i" -eq "$stage_idx" ]; then
      L+=("$icon <b>$label</b>")
    else
      L+=("$icon $label")
    fi
  done

  # ---- failure detail
  if [ "$status" = "FAILED" ]; then
    L+=("")
    L+=("$LUNA_CROSS <b>Failed stage:</b> $(luna_esc "${fail_stage:-unknown}")")
    if [ -n "$fail_msg" ]; then
      L+=("")
      L+=("<pre>$(luna_esc "$(luna_sanitize "$fail_msg" 500)")</pre>")
    fi
  fi

  # ---- artifacts (only from a verified listing)
  if [ -n "$artifact_file" ] && [ -f "$artifact_file" ]; then
    L+=("")
    L+=("$LUNA_FOLDER <b>ARTIFACTS</b>")
    local aname asize asha
    while IFS='|' read -r aname asize asha; do
      [ -z "${aname:-}" ] && continue
      local line
      line="$(luna_esc "$aname")"
      [ -n "${asize:-}" ] && line+=" <code>($(luna_esc "$(luna_human_size "$asize")"))</code>"
      L+=("$LUNA_FLOPPY $line")
      [ -n "${asha:-}" ] && L+=("   <code>sha256:$(luna_esc "${asha:0:16}")</code>")
    done < "$artifact_file"
  fi

  L+=("")
  L+=("$rule_line")
  L+=("$LUNA_GEAR Luna Build Agent $LUNA_RULE Live Monitoring")
  L+=("<i>updated $(luna_esc "$(luna_utc_human "$now")")</i>")

  printf '%s\n' "${L[@]}"
}

# ------------------------------------------------------------------- network --

luna_api() {
  # luna_api <endpoint> <curl args...>
  local ep="$1"; shift
  curl --silent --show-error --fail-with-body \
    --retry 3 --retry-delay 2 --max-time 30 \
    -X POST "https://api.telegram.org/bot${LUNA_TG_TOKEN}/${ep}" "$@"
}

luna_buttons() {
  case "$1" in
    SUCCESS)
      printf '{"inline_keyboard":[[{"text":"%s Download","url":"%s/artifacts"},{"text":"%s Logs","url":"%s"}]]}' \
        "$LUNA_FLOPPY" "$LUNA_RUN_URL" "$LUNA_MAG" "$LUNA_RUN_URL"
      ;;
    FAILED)
      printf '{"inline_keyboard":[[{"text":"%s Inspect failure","url":"%s"}]]}' \
        "$LUNA_BOOM" "$LUNA_RUN_URL"
      ;;
    *)
      printf '{"inline_keyboard":[[{"text":"%s Track build","url":"%s"}]]}' \
        "$LUNA_MAG" "$LUNA_RUN_URL"
      ;;
  esac
}

# Publish one message to every configured chat, editing in place when we
# already have a message id. Returns the number of chats updated.
luna_publish() {
  local text="$1" status="$2" force="${3:-0}"
  local sent=0 id resp msg_id

  luna_assert_no_secret "$text" || return 1

  # Rate limit non-critical edits.
  if [ "$force" != "1" ]; then
    local last; last="$(luna_state_get last_edit)"
    if [ -n "$last" ] && [ $(( $(luna_now_epoch) - last )) -lt "$LUNA_STAGE_MAX_EDIT_INTERVAL" ]; then
      luna_log "rate-limited: skipping non-critical update"
      return 0
    fi
  fi

  local markup; markup="$(luna_buttons "$status")"

  local ids
  # Replace separators with spaces, then let the unquoted expansion below split
  # on IFS whitespace. Do NOT use `tr -d '[:space:]'` here: that would delete
  # the very separators we just inserted and glue every id into one string.
  # Chat ids never contain spaces, so unquoted splitting is safe here.
  ids="$(printf '%s' "${LUNA_TG_CHAT_ID:-}" | tr ',;' '  ' | tr -d '\r')"

  for id in $ids; do
    [ -z "$id" ] && continue
    msg_id="$(luna_state_get "msg_$id")"

    if [ -n "$msg_id" ]; then
      # Edit in place. A "not modified" reply is a no-op, not a failure.
      if resp="$(luna_api editMessageText \
            --data-urlencode "chat_id=${id}" \
            --data-urlencode "message_id=${msg_id}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "disable_web_page_preview=true" \
            --data-urlencode "reply_markup=${markup}")"; then
        sent=$((sent + 1))
      elif printf '%s' "$resp" | grep -q 'message is not modified'; then
        luna_log "no textual change for chat ${id}; keeping message ${msg_id}"
        sent=$((sent + 1))
      else
        # Stale id (message deleted, or chat migrated): fall back to a new one.
        luna_warn "edit failed for chat ${id}, sending a new message: ${resp}"
        if resp="$(luna_api sendMessage \
              --data-urlencode "chat_id=${id}" \
              --data-urlencode "text=${text}" \
              --data-urlencode "parse_mode=HTML" \
              --data-urlencode "disable_web_page_preview=true" \
              --data-urlencode "disable_notification=true" \
              --data-urlencode "reply_markup=${markup}")"; then
          luna_extract_message_id "$resp" >/dev/null 2>&1 || true
          local new_id; new_id="$(luna_extract_message_id "$resp")"
          [ -n "$new_id" ] && luna_state_set "msg_$id" "$new_id"
          sent=$((sent + 1))
        else
          luna_warn "send failed for chat ${id}: ${resp}"
        fi
      fi
    else
      if resp="$(luna_api sendMessage \
            --data-urlencode "chat_id=${id}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "disable_web_page_preview=true" \
            --data-urlencode "reply_markup=${markup}")"; then
        local new_id; new_id="$(luna_extract_message_id "$resp")"
        if [ -n "$new_id" ]; then
          luna_state_set "msg_$id" "$new_id"
        else
          luna_warn "could not parse message_id for chat ${id}"
        fi
        sent=$((sent + 1))
      else
        luna_warn "send failed for chat ${id}: ${resp}"
      fi
    fi
  done

  luna_state_set last_edit "$(luna_now_epoch)"

  if [ "$sent" -eq 0 ]; then
    luna_err "no Telegram chat accepted the update"
    return 1
  fi
  luna_log "published '$status' to ${sent} chat(s)"
  return 0
}

# Pull result.message_id out of a sendMessage reply without needing jq.
luna_extract_message_id() {
  printf '%s' "$1" | grep -o '"message_id":[0-9]*' | head -n1 | cut -d: -f2
}