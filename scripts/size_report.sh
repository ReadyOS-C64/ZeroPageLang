#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="${ZEROPAGE_SIZE_BASELINE:-build/opt-baseline/round1/prg-sizes.tsv}"
OUT_DIR="$ROOT_DIR/build/size-report"
TSV="$OUT_DIR/prg-sizes.tsv"
SUMMARY="$OUT_DIR/summary.md"

cd "$ROOT_DIR"
mkdir -p "$OUT_DIR"

baseline_size() {
  local path="$1"
  if [[ -f "$BASELINE" ]]; then
    awk -F '\t' -v p="$path" 'NR > 1 && $1 == p { print $2; exit }' "$BASELINE"
  fi
}

{
  printf 'path\tprg_bytes\tpayload_bytes\tload_hex\tdelta_bytes\tdelta_percent\n'
  find build -type f -name '*.prg' \
    ! -path 'build/opt-baseline/*' \
    ! -path 'build/opt-after/*' \
    ! -path 'build/refactor-baseline/*' \
    ! -path 'build/refactor-after/*' \
    ! -path 'build/size-report/*' \
    -print | sort | while IFS= read -r path; do
      size="$(wc -c < "$path" | tr -d '[:space:]')"
      payload="$((size - 2))"
      load="$(od -An -tx1 -N2 "$path" | awk '{print toupper($2 $1)}')"
      before="$(baseline_size "$path")"
      if [[ -n "${before:-}" ]]; then
        delta="$((size - before))"
        pct="$(awk -v d="$delta" -v b="$before" 'BEGIN { if (b == 0) print ""; else printf "%.2f", (d * 100.0) / b }')"
      else
        delta=""
        pct=""
      fi
      printf '%s\t%s\t%s\t$%s\t%s\t%s\n' "$path" "$size" "$payload" "$load" "$delta" "$pct"
    done
} > "$TSV"

total_count="$(awk 'NR > 1 { count++ } END { print count + 0 }' "$TSV")"
total_bytes="$(awk -F '\t' 'NR > 1 { sum += $2 } END { print sum + 0 }' "$TSV")"
total_delta="$(awk -F '\t' 'NR > 1 && $5 != "" { sum += $5 } END { print sum + 0 }' "$TSV")"

{
  echo "# ZeroPage PRG Size Report"
  echo
  echo "- PRG count: $total_count"
  echo "- Total PRG bytes: $total_bytes"
  if [[ -f "$BASELINE" ]]; then
    echo "- Baseline: \`$BASELINE\`"
    echo "- Total delta bytes: $total_delta"
  else
    echo "- Baseline: none"
  fi
  echo
  python3 scripts/optimization_report.py abi-sizes "$TSV"
  echo "## Largest PRGs"
  echo
  echo "| PRG | Bytes | Delta |"
  echo "| --- | ---: | ---: |"
  awk -F '\t' 'NR > 1 { print $1 "\t" $2 "\t" $5 }' "$TSV" | sort -t $'\t' -k2,2nr | awk 'NR <= 20' | while IFS=$'\t' read -r path size delta; do
    [[ -z "$delta" ]] && delta="-"
    echo "| \`$path\` | $size | $delta |"
  done
  echo
  echo "## Biggest Shrinks"
  echo
  echo "| PRG | Bytes | Delta |"
  echo "| --- | ---: | ---: |"
  awk -F '\t' 'NR > 1 && $5 != "" { print $1 "\t" $2 "\t" $5 }' "$TSV" | sort -t $'\t' -k3,3n | awk 'NR <= 20' | while IFS=$'\t' read -r path size delta; do
    echo "| \`$path\` | $size | $delta |"
  done
  echo
  echo "## Biggest Growth"
  echo
  echo "| PRG | Bytes | Delta |"
  echo "| --- | ---: | ---: |"
  awk -F '\t' 'NR > 1 && $5 != "" { print $1 "\t" $2 "\t" $5 }' "$TSV" | sort -t $'\t' -k3,3nr | awk 'NR <= 20' | while IFS=$'\t' read -r path size delta; do
    echo "| \`$path\` | $size | $delta |"
  done
} > "$SUMMARY"

echo "wrote $TSV"
echo "wrote $SUMMARY"
