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
#
# Safety invariants enforced here (each one has a regression test):
#   S1  The bot token is never interpolated into a sed pattern or any regex.
#   S2  Every rendered payload is clamped to the Telegram message limit, so a
#       large artifact listing can never turn into a silent HTTP 400.
#   S3  Chat ids are validated and turned into safe state filenames, so a
#       hostile or malformed id cannot traverse out of the state directory.
#   S4  Untrusted text is escaped before it is written to a ::notice:: log
#       command, so it cannot forge a workflow command.
#   S5  Values spliced into reply_markup JSON are JSON-escaped.
#   S6  Nothing user-supplied is ever used as a glob pattern.

set -uo pipefail

# ---------------------------------------------------------------- constants --

# Canonical pipeline. Every stage here maps to real steps in build.yml.
# Order matters: the rendered checklist follows this list.
#
# Workflows reference stages BY NAME (luna_stage_index) rather than by magic
# index, so reordering this list can never silently desynchronise the wiring.
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

# Index of the terminal stage, derived so it can never drift out of range.
LUNA_LAST_STAGE=$(( ${#LUNA_STAGES[@]} - 1 ))

LUNA_RULE="—"                 # em dash rule
LUNA_MOON="🌙"                 # moon face
LUNA_PENGUIN="🐧"              # linux penguin
LUNA_CLOCK="🕒"                # clock face
LUNA_STOPWATCH="⏱"            # stopwatch
LUNA_DOWN="📥"                 # inbox / fetch
LUNA_CHECK="✅"                # check mark
LUNA_SPIN="🔄"                 # arrows / active
LUNA_PEND="⏳"                # hourglass / pending
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

# Telegram rejects any message longer than 4096 UTF-16 code units. Several of
# our glyphs (the moon face, the rocket) are outside the BMP and therefore cost
# two code units each, so clamping on a plain character count would still be
# able to overshoot. We clamp conservatively below the hard limit instead of
# computing UTF-16 width, which would drag awk/python into the hot path.
LUNA_MESSAGE_LIMIT="${LUNA_MESSAGE_LIMIT:-3900}"

# Literal newline, used for line-boundary-safe truncation.
NL=$'\n'

# A pathological artifact listing must not be able to push the body over the
# limit even after the error block is accounted for.
LUNA_MAX_ARTIFACT_LINES="${LUNA_MAX_ARTIFACT_LINES:-10}"

# ------------------------------------------------------------------ helpers --

# Escape text for a GitHub Actions workflow command (::notice::/::warning::/
# ::error::). Untrusted text reaching this function could otherwise inject a
# newline and forge an arbitrary workflow command. Invariant S4.
luna_gh_escape() {
  local s="$1"
  # % first: its own escape introduces a '%' that must not be re-escaped.
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

luna_log()  { local m; m="$(luna_gh_escape "$*")"; printf '::notice::%s\n' "$m" >&2; }
luna_warn() { local m; m="$(luna_gh_escape "$*")"; printf '::warning::%s\n' "$m" >&2; }
luna_err()  { local m; m="$(luna_gh_escape "$*")"; printf '::error::%s\n'   "$m" >&2; }

luna_now_epoch() { date -u '+%s'; }

luna_utc_human() {
  # 2026-10-10T12:02:50Z -> "2026-10-10 12:02:50 UTC"
  date -u -d "@${1:-$(luna_now_epoch)}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
    || date -u '+%Y-%m-%d %H:%M:%S UTC'
}

luna_elapsed() {
  # Seconds -> HH:MM:SS
  local s=${1:-0}
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  [ "$s" -lt 0 ] && s=0
  printf '%02d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

luna_duration_short() {
  # Seconds -> "4m 12s" / "12s" / "1h 03m". Used for per-stage timings.
  local s=${1:-0}
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  [ "$s" -lt 0 ] && s=0
  if   [ "$s" -ge 3600 ]; then printf '%dh %02dm' $((s / 3600)) $(((s % 3600) / 60))
  elif [ "$s" -ge 60 ];   then printf '%dm %02ds' $((s / 60)) $((s % 60))
  else                         printf '%ds' "$s"
  fi
}

luna_human_size() {
  # Bytes -> compact size. Falls back to raw bytes when unknown.
  local b=${1:-0}
  # Guard the arithmetic: a non-numeric size field from an artifact listing
  # would otherwise make `[` fail and `%d` emit a runtime error.
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if   [ "$b" -ge 1073741824 ]; then printf '%d.%d GB' $((b / 1073741824)) $(((b % 1073741824) * 10 / 1073741824))
  elif [ "$b" -ge 1048576 ];    then printf '%d.%d MB' $((b / 1048576))    $(((b % 1048576) * 10 / 1048576))
  elif [ "$b" -ge 1024 ];       then printf '%d.%d KB' $((b / 1024))       $(((b % 1024) * 10 / 1024))
  else printf '%s B' "$b"; fi
}

# Escape for Telegram HTML parse mode. Applied to every interpolated value.
luna_esc() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Escape a value for embedding inside a JSON string literal. Invariant S5.
luna_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # Control characters must be escaped; the remaining ones are whitespace we
  # already collapsed, but be explicit rather than rely on that.
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Literal replacement of every occurrence of a fixed needle.
#
# This exists so the token scrubber never has to build a regex (invariant S1).
# A token containing '/', '&', '.' or '\' previously produced either a sed
# syntax error - which discarded the entire buffer - or wrong substitutions.
luna_replace_literal() {
  local haystack="$1" needle="$2" replacement="$3"
  [ -z "$needle" ] && { printf '%s' "$haystack"; return 0; }
  printf '%s' "${haystack//"$needle"/"$replacement"}"
}

# Strip ANSI escapes, redact the bot token and anything token-shaped, collapse
# whitespace, and hard-truncate. Used on any log-derived text.
luna_sanitize() {
  local text="$1" limit="${2:-600}"
  [ -z "$text" ] && { printf ''; return 0; }

  # Remove CSI colour sequences.
  text="$(printf '%s' "$text" | sed -e 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' -e 's/\r//g')"

  # Redact the real token if present. Literal replacement, never a regex: the
  # token is opaque data and must not be compiled as a pattern.
  if [ -n "${LUNA_TG_TOKEN:-}" ]; then
    text="$(luna_replace_literal "$text" "$LUNA_TG_TOKEN" '[REDACTED]')"
  fi
  # Redact anything that structurally looks like a bot token. The pattern here
  # is a constant, so the regex is safe.
  text="$(printf '%s' "$text" | sed -E 's/[0-9]{6,12}:[A-Za-z0-9_-]{30,}/[REDACTED_TOKEN]/g')"

  # Collapse to a single line so Telegram markup stays predictable.
  text="$(printf '%s' "$text" | tr '\n\t' '  ' | tr -s ' ')"

  # Trim to the limit.
  printf '%s' "$text" | cut -c1-"$limit"
}

# Hard guarantee that the rendered payload cannot contain the token. Every
# field that is actually put on the wire is checked, not just the body text.
luna_assert_no_secret() {
  [ -z "${LUNA_TG_TOKEN:-}" ] && return 0
  local payload
  for payload in "$@"; do
    case "$payload" in
      *"${LUNA_TG_TOKEN}"*)
        luna_err "Refusing to send: rendered payload contains the bot token."
        return 1
        ;;
    esac
  done
  return 0
}

# -------------------------------------------------------------------- state --

luna_state_dir() {
  local base="${LUNA_STATE_DIR:-${RUNNER_TEMP:-/tmp}}"
  printf '%s/luna-agent-%s' "$base" "${LUNA_RUN_ID:-local}"
}

# Turn an arbitrary chat id into a filename-safe, collision-free state key.
# Invariant S3: ids reach the filesystem only through this function.
#   * plain integers (the normal case) are used verbatim, so state stays
#     greppable and the existing behaviour is preserved;
#   * anything else (@usernames, malformed input) gets a stable checksum key.
luna_state_key() {
  local id="$1"
  case "$id" in
    ''|-*[!0-9]*|*[!0-9-]*|*-) printf 'x%s' "$(printf '%s' "$id" | cksum | cut -d' ' -f1)"; return 0 ;;
  esac
  printf '%s' "$id"
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
# stages file format:  <index> <TAB> <status>   status in done|active|failed|pending
# Rendering walks LUNA_STAGES and looks each one up here.

# Write every stage as pending. Used to seed an empty table.
luna_stage_seed() {
  local d; d="$(luna_state_init)" || return 1
  local tmp="$d/stages.tmp" i
  : > "$tmp"
  for i in "${!LUNA_STAGES[@]}"; do
    printf '%s\tpending\n' "$i" >> "$tmp"
  done
  mv "$tmp" "$d/stages"
}

# Index of the stage currently marked active, or empty when none is.
luna_stage_active_idx() {
  local d; d="$(luna_state_dir)"
  [ -f "$d/stages" ] || return 0
  local idx_s st
  while IFS=$'\t' read -r idx_s st; do
    if [ "${st:-}" = "active" ]; then printf '%s' "$idx_s"; return 0; fi
  done < "$d/stages"
}

# Resolve a stage name to its index. Returns -1 when unknown.
# This is what lets workflows wire stages by name and stay in sync with the
# canonical list above.
luna_stage_index() {
  local want="$1" i
  for i in "${!LUNA_STAGES[@]}"; do
    if [ "${LUNA_STAGES[$i]}" = "$want" ]; then printf '%s' "$i"; return 0; fi
  done
  printf -- '-1'
}

# Seal the currently active stage, recording how long it took.
luna_stage_seal() {
  local t0; t0="$(luna_state_get stage_t0)"
  case "$t0" in ''|*[!0-9]*) return 0 ;; esac
  local idx; idx="$(luna_stage_active_idx)"
  [ -n "$idx" ] || return 0
  luna_state_set "dur_$idx" $(( $(luna_now_epoch) - t0 ))
}

luna_stage_mark() {
  local idx="$1" status="$2"
  local d; d="$(luna_state_dir)"
  # `-s`, not `-f`: luna_state_init creates an *empty* stages file, and reading
  # that yields no rows, so an unconditional mark would be silently discarded.
  [ -s "$d/stages" ] || luna_stage_seed || return 1
  local tmp="$d/stages.tmp"
  : > "$tmp"
  local idx_s line_s
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

# Mark every stage before `upto` done, `upto` $status, rest pending.
# Seals the outgoing stage so per-stage durations accumulate across the run.
luna_stage_set_current() {
  local upto="$1" status="${2:-active}"
  case "$upto" in ''|*[!0-9]*) upto=0 ;; esac
  luna_state_init >/dev/null || return 1
  luna_stage_seal
  local d; d="$(luna_state_dir)"
  local tmp="$d/stages.tmp"
  : > "$tmp"
  local i s
  for i in "${!LUNA_STAGES[@]}"; do
    if   [ "$i" -lt "$upto" ]; then s="done"
    elif [ "$i" -eq "$upto" ]; then s="$status"
    else                             s="pending"
    fi
    printf '%s\t%s\n' "$i" "$s" >> "$tmp"
  done
  mv "$tmp" "$d/stages"
  case "$status" in
    active) luna_state_set stage_t0 "$(luna_now_epoch)" ;;
    *)      : > /dev/null ;;
  esac
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

# Recorded duration for a completed stage, or empty when it never ran.
luna_stage_duration() {
  local v; v="$(luna_state_get "dur_$1")"
  case "$v" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$v" ;; esac
}

# Highest-index stage the pipeline has reached, or -1 when nothing has started.
#
# This is what lets a failure that happens *between* notifications still be
# attributed to a real stage. A workflow cannot know precisely which step died,
# but the agent knows how far the pipeline actually got, so it can say
# "Apply Patches" instead of guessing a single hardcoded label for every
# possible failure in the job.
luna_stage_furthest_idx() {
  local i last=-1 st
  for i in "${!LUNA_STAGES[@]}"; do
    st="$(luna_stage_status "$i")"
    [ "$st" = "pending" ] || last="$i"
  done
  printf '%s' "$last"
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

# Append any HTML tags that a truncation left open.
#
# We only ever generate b / code / i / pre, and each is opened and closed
# within a rendered line, so counting and topping up is sufficient and far
# cheaper than parsing. Closers are appended innermost-first so the result is
# properly nested rather than merely balanced.
luna_bal_tags() {
  local s="$1" t
  for t in pre i code b; do
    local o c
    o="$(printf '%s' "$s" | grep -o "<$t>" | wc -l | tr -d ' ')"
    c="$(printf '%s' "$s" | grep -o "</$t>" | wc -l | tr -d ' ')"
    case "$o" in ''|*[!0-9]*) o=0 ;; esac
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    while [ "$o" -gt "$c" ]; do
      s="$s</$t>"
      c=$((c + 1))
    done
  done
  printf '%s' "$s"
}

# Truncate a single value (e.g. an absurdly long artifact filename).
luna_trunc_value() {
  local s="$1" max="${2:-120}"
  case "$max" in ''|*[!0-9]*) max=120 ;; esac
  if [ "${#s}" -le "$max" ]; then printf '%s' "$s"; return 0; fi
  printf '%s…' "${s:0:$((max - 1))}"
}

# Clamp a rendered message to the Telegram limit. Invariant S2.
#
# Telegram rejects both an over-long message *and* unbalanced markup, so a
# naive character cut is not enough: it turns a cosmetic overflow into a
# completely missing notification. Three defences, in order:
#   1. cut to the limit;
#   2. never cut inside a tag, and prefer a line boundary;
#   3. close any tag that is still open.
luna_clamp() {
  local s="$1" limit="${2:-$LUNA_MESSAGE_LIMIT}"
  case "$limit" in ''|*[!0-9]*) limit=3900 ;; esac
  if [ "${#s}" -le "$limit" ]; then printf '%s' "$s"; return 0; fi

  local marker='…[truncated]'
  local room=$(( limit - ${#marker} ))
  [ "$room" -lt 1 ] && { printf '%s' "${s:0:$limit}"; return 0; }

  local head="${s:0:$room}"

  # If the cut landed inside a tag, back off to just before that '<'.
  # ${head%<*} removes the shortest suffix beginning at the last '<'.
  if [ -n "${head##*<}" ]; then
    head="${head%<*}"
  fi

  # Prefer cutting on a line boundary, but only when that does not throw away
  # most of the message (one huge line would otherwise lose everything).
  if [ "${head%$NL*}" != "$head" ]; then
    local on_line="${head%$NL*}"
    if [ "${#on_line}" -ge $(( room / 2 )) ]; then
      head="$on_line"
    fi
  fi

  printf '%s%s' "$(luna_bal_tags "$head")" "$marker"
}

# luna_render <status> <stage_index> <failure_stage> <error_summary> <artifact_file>
# Builds the message as an array of lines and joins them with real newlines.
# (String concatenation + `$(printf '...\n')` loses trailing newlines, which
# silently welded every field onto one line.)
luna_render() {
  local status="$1" stage_idx="${2:--1}" fail_stage="${3:-}" fail_msg="${4:-}"
  local artifact_file="${5:-}"
  case "$stage_idx" in ''|*[!0-9-]*) stage_idx="-1" ;; esac

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
  local i st icon label dur
  for i in "${!LUNA_STAGES[@]}"; do
    st="$(luna_stage_status "$i")"
    label="$(luna_esc "${LUNA_STAGES[$i]}")"
    case "$st" in
      done|success) icon="$LUNA_CHECK" ;;
      active)       icon="$LUNA_SPIN" ;;
      failed)       icon="$LUNA_CROSS" ;;
      *)            icon="$LUNA_PEND" ;;
    esac
    # Per-stage timings, only for stages that actually ran to completion.
    dur="$(luna_stage_duration "$i")"
    if [ -n "$dur" ] && [ "$st" = "done" ]; then
      label+=" <i>($(luna_esc "$(luna_duration_short "$dur")"))</i>"
    fi
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
    local aname asize asha shown=0 skipped=0
    while IFS='|' read -r aname asize asha; do
      [ -z "${aname:-}" ] && continue
      if [ "$shown" -ge "$LUNA_MAX_ARTIFACT_LINES" ]; then
        skipped=$((skipped + 1))
        continue
      fi
      shown=$((shown + 1))
      local line
      line="$(luna_esc "$(luna_trunc_value "$aname" 120)")"
      [ -n "${asize:-}" ] && line+=" <code>($(luna_esc "$(luna_human_size "$asize")"))</code>"
      L+=("$LUNA_FLOPPY $line")
      [ -n "${asha:-}" ] && L+=("   <code>sha256:$(luna_esc "${asha:0:16}")</code>")
    done < "$artifact_file"
    if [ "$skipped" -gt 0 ]; then
      L+=("<i>+ $skipped more file(s) not listed</i>")
    fi
  fi

  L+=("")
  L+=("$rule_line")
  L+=("$LUNA_GEAR Luna Build Agent $LUNA_RULE Live Monitoring")
  L+=("<i>updated $(luna_esc "$(luna_utc_human "$now")")</i>")

  # Final clamp is the hard guarantee that this payload is always sendable.
  luna_clamp "$(printf '%s\n' "${L[@]}")"
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
  # Every interpolated value is JSON-escaped (invariant S5) so a repository
  # slug or server URL containing a quote cannot produce malformed markup.
  local url; url="$(luna_json_str "${LUNA_RUN_URL:-}")"
  case "$1" in
    SUCCESS)
      printf '{"inline_keyboard":[[{"text":"%s Download","url":"%s/artifacts"},{"text":"%s Logs","url":"%s"}]]}' \
        "$LUNA_FLOPPY" "$url" "$LUNA_MAG" "$url"
      ;;
    FAILED)
      printf '{"inline_keyboard":[[{"text":"%s Inspect failure","url":"%s"}]]}' \
        "$LUNA_BOOM" "$url"
      ;;
    *)
      printf '{"inline_keyboard":[[{"text":"%s Track build","url":"%s"}]]}' \
        "$LUNA_MAG" "$url"
      ;;
  esac
}

# Split the configured chat id list into individual, validated ids on stdout.
# One id per line. Never treats the value as a glob (invariant S6).
luna_chat_ids() {
  local raw="${LUNA_TG_CHAT_ID:-}"
  [ -z "$raw" ] && return 0
  local id
  # `|| [ -n "$id" ]` is required: the tr that produced this stream does not
  # emit a trailing newline, so a plain `read` would drop the final chat id.
  while IFS= read -r id || [ -n "$id" ]; do
    id="${id#"${id%%[![:space:]]*}"}"   # ltrim
    id="${id%"${id##*[![:space:]]}"}"   # rtrim
    [ -z "$id" ] && continue
    # Only accept what Telegram itself accepts as a target: an @username, or a
    # numeric id (negative for supergroups/channels). The @branch must be
    # tested FIRST: a blanket non-numeric check would reject every username.
    case "$id" in
      @*)
        case "${id#@}" in
          ''|*[!A-Za-z0-9_]*) luna_warn "ignoring malformed chat id '${id}'"; continue ;;
        esac ;;
      -*[!0-9]*|*[!0-9-]*|-)
        luna_warn "ignoring malformed chat id '${id}'"; continue ;;
    esac
    printf '%s\n' "$id"
  # Split on commas, semicolons and any whitespace. The previous version used
  # unquoted word splitting, so space-separated ids worked there and must keep
  # working here - just without the globbing that came with it.
  done < <(printf '%s' "$raw" | tr ',;[:space:]' '\n')
}

# Publish one message to every configured chat, editing in place when we
# already have a message id. Returns the number of chats updated.
#
#   luna_publish <text> <status> <force> [silent] [fresh]
#
# silent  - send with disable_notification=true, so intermediate stage updates
#           do not ping a whole channel.
# fresh   - always send a NEW message instead of editing the live one.
#
# `fresh` exists because Telegram does not raise a notification when a message
# is *edited*. Sending the final SUCCESS/FAILED state as an edit therefore
# produced a result the channel never saw: the build finished and nobody was
# told. Terminal states post a fresh message (which pings, if the chat allows
# it) while intermediate updates keep editing the single live message.
luna_publish() {
  local text="$1" status="$2" force="${3:-0}" silent="${4:-0}" fresh="${5:-0}"
  local sent=0 id resp msg_id

  local markup; markup="$(luna_buttons "$status")"

  # Check every field that goes on the wire, not just the body.
  luna_assert_no_secret "$text" "$markup" "${LUNA_TG_CHAT_ID:-}" || return 1

  # Rate limit non-critical edits.
  if [ "$force" != "1" ]; then
    local last; last="$(luna_state_get last_edit)"
    if [ -n "$last" ] && [ $(( $(luna_now_epoch) - last )) -lt "$LUNA_STAGE_MAX_EDIT_INTERVAL" ]; then
      luna_log "rate-limited: skipping non-critical update"
      return 0
    fi
  fi

  # Intermediate updates stay silent unless explicitly told otherwise.
  local dn="true"
  case "$silent:$status" in
    1:RUNNING) dn="true" ;;
    *)         dn="false" ;;
  esac

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    msg_id=""
    [ "$fresh" = "1" ] || msg_id="$(luna_state_get "msg_$(luna_state_key "$id")")"

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
              --data-urlencode "disable_notification=${dn}" \
              --data-urlencode "reply_markup=${markup}")"; then
          local new_id; new_id="$(luna_extract_message_id "$resp")"
          [ -n "$new_id" ] && luna_state_set "msg_$(luna_state_key "$id")" "$new_id"
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
            --data-urlencode "disable_notification=${dn}" \
            --data-urlencode "reply_markup=${markup}")"; then
        local new_id; new_id="$(luna_extract_message_id "$resp")"
        if [ -n "$new_id" ]; then
          luna_state_set "msg_$(luna_state_key "$id")" "$new_id"
        else
          luna_warn "could not parse message_id for chat ${id}"
        fi
        sent=$((sent + 1))
      else
        luna_warn "send failed for chat ${id}: ${resp}"
      fi
    fi
  done < <(luna_chat_ids)

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
