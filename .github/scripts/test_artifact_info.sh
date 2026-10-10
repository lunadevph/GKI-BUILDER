#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/luna_artifact_info.sh"

T="$(mktemp -d)"
mkdir -p "$T/sub"
head -c 1048576 /dev/urandom > "$T/Image"
printf 'echo hi\n' > "$T/anykernel.sh"
head -c 2048 /dev/urandom > "$T/sub/dtb"
printf 'name with spaces\n' > "$T/file with spaces.txt"

echo "--- populated dir ---"
bash "$SCRIPT" "$T" 10
echo "exit=$?"

echo
echo "--- verify size + sha are correct for Image ---"
real_size="$(wc -c < "$T/Image" | tr -d ' ')"
real_sha="$(sha256sum "$T/Image" | cut -d' ' -f1)"
got="$(bash "$SCRIPT" "$T" 10 | grep '^Image|')"
echo "expected size=$real_size"
echo "expected sha =$real_sha"
echo "got          =$got"
case "$got" in
  "Image|$real_size|$real_sha") echo "MATCH_OK" ;;
  *) echo "MATCH_FAIL" ;;
esac

echo
echo "--- max files honoured ---"
echo "count=$(bash "$SCRIPT" "$T" 2 | grep -c '|')  (expect 2)"

echo
echo "--- empty dir (expect failure) ---"
E="$(mktemp -d)"
bash "$SCRIPT" "$E" 10
echo "exit=$? (expect 1)"

echo
echo "--- missing dir (expect failure) ---"
bash "$SCRIPT" /definitely/not/here 10
echo "exit=$? (expect 1)"

rm -rf "$T" "$E"