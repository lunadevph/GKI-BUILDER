#!/usr/bin/env bash
# Extract the *real* reason a Luna kernel build failed.
#
# Before this existed the notification agent could only ever say "see the run
# log", which is useless in a chat window: the reader has neither the log nor
# any reason to open a browser. This turns a raw build log into a short,
# bounded, human-readable diagnosis.
#
# Strategy:
#   1. Anchor on the fatal `make: *** [...] Error N` line and pull the failing
#      target out of it. That is the one line that is always present.
#   2. Take the genuine compiler/linker diagnostics (`error:`, `undefined
#      reference`, ...) that appear *above* the anchor. Real kernel build logs
#      put the cause above the make failure, never below.
#   3. Fall back to the last diagnostics in the file, then to the tail, when no
#      anchor exists (bazel/kleaf builds, or a failure before make).
#
# Performance note: this runs in CI against logs that are routinely 100k+
# lines long, so it is deliberately batch-oriented. It issues a fixed, small
# number of `grep`/`head`/`sed` passes over the file and never forks per line.
#
# Output is bounded on both lines and characters so it can never be the thing
# that overflows a Telegram message. Nothing here interprets the log as code.

set -uo pipefail

LOG="${1:-}"
MAX_LINES="${2:-14}"
MAX_CHARS="${3:-900}"

if [ -z "$LOG" ] || [ ! -f "$LOG" ] || [ ! -r "$LOG" ]; then
  # Diagnostics are strictly best effort; never fail the build over this.
  echo "No build log was available to diagnose the failure." >&2
  exit 0
fi

case "$MAX_LINES" in ''|*[!0-9]*) MAX_LINES=14 ;; esac
case "$MAX_CHARS"  in ''|*[!0-9]*) MAX_CHARS=900 ;; esac

# Anchor: the fatal make line. GNU make writes either
#   make: *** [Makefile:123: target] Error 2
# or, under -j,
#   make[123]: *** [Makefile:45: target/subdir.o] Error 1
ANCHOR_RE='^make(\[[0-9]+\])?: \*\*\* \['

# Genuine diagnostics worth surfacing.
DIAG_RE='(error:|fatal error:|undefined reference|collect2:|ld\.lld:|clang(-[0-9]+)?: *error|No rule to make target|recipe for target.*failed|Section mismatch|Unsupported reloc|not recognized|Cannot find|is not a GNU Makefile|scripts/[a-z0-9-]+\.sh: line )'

# Strip make's "  CC [M]  " / "123: " decoration in one pass over the block.
dedecorate() { sed -e 's/^[[:space:]]*[0-9]\{1,7\}[[:space:]]*//' -e 's/^[[:space:]]*//'; }

out=()
target=""

anchor_hit="$(grep -nE "$ANCHOR_RE" "$LOG" 2>/dev/null | head -n 1)"
if [ -n "$anchor_hit" ]; then
  anchor_line="${anchor_hit%%:*}"
  anchor_text="${anchor_hit#*:}"
  target="$(printf '%s' "$anchor_text" \
    | sed -n 's/^.*\*\*\* \[\([^:]*\):[0-9]*: *\(.*\)\] Error.*$/\2/p')"

  out+=("$anchor_text")

  # The proximate cause sits just above the anchor. Grab the last few matching
  # lines from everything before it in a single pass.
  above=$((anchor_line - 1))
  if [ "$above" -ge 1 ]; then
    diag_block="$(head -n "$above" "$LOG" 2>/dev/null | grep -E "$DIAG_RE" | tail -n 4 | dedecorate)"
    if [ -n "$diag_block" ]; then
      mapfile -t diag_lines < <(printf '%s\n' "$diag_block")
      for line in "${diag_lines[@]}"; do
        [ -n "$line" ] || continue
        dup=0
        for existing in "${out[@]:-}"; do
          if [ "$existing" = "$line" ]; then dup=1; break; fi
        done
        [ "$dup" -eq 0 ] && out+=("$line")
      done
    fi
  fi
else
  # No make anchor (bazel/kleaf, or a failure before make). Take the *last*
  # diagnostics rather than the first: the proximate cause comes after any
  # incidental earlier warnings.
  diag_block="$(grep -E "$DIAG_RE" "$LOG" 2>/dev/null | tail -n "$MAX_LINES" | dedecorate)"
  if [ -n "$diag_block" ]; then
    mapfile -t diag_lines < <(printf '%s\n' "$diag_block")
    for line in "${diag_lines[@]}"; do
      [ -n "$line" ] && out+=("$line")
    done
  else
    diag_tail="$(mktemp)"
    if tail -n 6 "$LOG" 2>/dev/null | dedecorate | grep -q '[^[:space:]]'; then
      out+=("Build failed without a recognisable compiler error.")
      out+=("Last output:")
      tail -n 6 "$LOG" 2>/dev/null | dedecorate | while IFS= read -r line; do
        [ -n "$line" ] && printf '  %s\n' "$line"
      done > "$diag_tail"
      mapfile -t tail_lines < <(cat "$diag_tail")
      for line in "${tail_lines[@]}"; do
        [ -n "$line" ] && out+=("$line")
      done
    else
      out+=("Build failed without any output to diagnose the cause.")
    fi
    rm -f "$diag_tail"
  fi
fi

if [ -n "$target" ]; then
  out+=("")
  out+=("Failing target: $target")
fi

# Bound the line count, then the character count, then emit.
if [ "${#out[@]}" -gt "$MAX_LINES" ]; then
  mapfile -t out < <(printf '%s\n' "${out[@]:0:$MAX_LINES}")
fi

text="$(printf '%s\n' "${out[@]+"${out[@]}"}")"
if [ "${#text}" -gt "$MAX_CHARS" ]; then
  text="${text:0:$((MAX_CHARS - 20))}
...[truncated]"
fi

printf '%s\n' "$text"
exit 0
