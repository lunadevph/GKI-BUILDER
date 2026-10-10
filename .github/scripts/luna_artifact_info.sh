#!/usr/bin/env bash
# Emit verified artifact facts as  name|size_bytes|sha256  lines.
#
# Only files that actually exist are reported, so the Telegram agent can never
# claim an artifact that was not produced. Checksums are real sha256 of the real
# file contents.

set -uo pipefail

DIR="${1:-}"
MAX_FILES="${2:-10}"

if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  printf 'ERROR: artifact directory not found: %s\n' "${DIR:-<empty>}" >&2
  exit 1
fi

count=0
# -print0 / read -d '' so filenames with spaces or newlines survive.
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
  [ -z "$size" ] && continue

  sha=""
  if command -v sha256sum >/dev/null 2>&1; then
    sha="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    sha="$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1)"
  fi

  printf '%s|%s|%s\n' "$name" "$size" "${sha:-}"
  count=$((count + 1))
  [ "$count" -ge "$MAX_FILES" ] && break
done < <(find "$DIR" -maxdepth 3 -type f -print0 2>/dev/null | sort -z)

if [ "$count" -eq 0 ]; then
  printf 'ERROR: no files found under %s\n' "$DIR" >&2
  exit 1
fi

exit 0