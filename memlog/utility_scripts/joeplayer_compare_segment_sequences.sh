#!/usr/bin/env bash
# Compare ordered segment URI lists for JoePlayer / JoesProxy HLS trials.
# Usage:
#   joeplayer_compare_segment_sequences.sh expected.txt captured.txt
# Each file is one URI (or path suffix) per line. Prints classification:
#   ok | repeat | skip | reorder | length_mismatch
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 expected.txt captured.txt" >&2
  exit 2
fi

expected="$1"
captured="$2"

if [ ! -f "$expected" ] || [ ! -f "$captured" ]; then
  echo "missing input file(s)" >&2
  exit 2
fi

# Portable line load (macOS Bash 3.2 has no mapfile).
exp=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "${line// }" ] && continue
  exp+=("$line")
done < "$expected"

cap=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "${line// }" ] && continue
  cap+=("$line")
done < "$captured"

if [ "${#exp[@]}" -eq 0 ]; then
  echo "empty expected sequence" >&2
  exit 2
fi

if [ "${#exp[@]}" -ne "${#cap[@]}" ]; then
  echo "length_mismatch expected=${#exp[@]} captured=${#cap[@]}"
  exit 1
fi

repeat=0
skip=0
mismatch=0
i=0
while [ "$i" -lt "${#exp[@]}" ]; do
  e="${exp[$i]}"
  c="${cap[$i]}"
  if [ "$e" != "$c" ]; then
    mismatch=$((mismatch + 1))
    if [ "$i" -gt 0 ]; then
      prev="${cap[$((i - 1))]}"
      if [ "$c" = "$prev" ]; then
        repeat=$((repeat + 1))
      fi
    fi
    next_i=$((i + 1))
    if [ "$next_i" -lt "${#exp[@]}" ]; then
      next="${exp[$next_i]}"
      if [ "$c" = "$next" ]; then
        skip=$((skip + 1))
      fi
    fi
  fi
  i=$((i + 1))
done

if [ "$mismatch" -eq 0 ]; then
  echo "ok"
  exit 0
fi

if [ "$repeat" -gt 0 ] && [ "$skip" -eq 0 ]; then
  echo "repeat count=$repeat mismatches=$mismatch"
  exit 1
fi
if [ "$skip" -gt 0 ] && [ "$repeat" -eq 0 ]; then
  echo "skip count=$skip mismatches=$mismatch"
  exit 1
fi
echo "reorder mismatches=$mismatch repeat=$repeat skip=$skip"
exit 1
