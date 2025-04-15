#!/bin/bash

# Defaults
TARGET="${1:-$HOME}"
DEPTH=4
LIMIT=30
USE_EXCLUDES=1
EXCLUDES_FILE="$(dirname "$0")/../config/backup_excludes/$(whoami)@$(hostname)"

# Enable globstar and extglob for advanced matching
shopt -s globstar extglob nullglob

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --depth=*)
      DEPTH="${1#*=}"
      shift
      ;;
    --limit=*)
      LIMIT="${1#*=}"
      shift
      ;;
    --no-excludes)
      USE_EXCLUDES=0
      shift
      ;;
    /*)
      TARGET="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "🔍 Scanning: $TARGET"
echo "🧭 Max depth: $DEPTH"
echo "📉 Showing top $LIMIT entries"
echo

TMP_FILE=$(mktemp)

printf "%-10s  %10s  %8s  %-20s  %s\n" "Size" "Files" "Dirs" "Top-Level" "Path"

# Read and compile exclude patterns
EXCLUDES=()
if [[ "$USE_EXCLUDES" == "1" && -f "$EXCLUDES_FILE" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    EXCLUDES+=("$line")
  done < "$EXCLUDES_FILE"
fi

# Main scan
find "$TARGET" -mindepth 1 -maxdepth "$DEPTH" -type d | while read -r dir; do
  skip=0

  # Check against all exclude patterns using glob matching
  for pattern in "${EXCLUDES[@]}"; do
    # Expand leading ~ and remove trailing slash
    pattern="${pattern/#\~/$HOME}"
    pattern="${pattern%/}"

    if [[ "$dir" == $pattern || "$dir"/ == $pattern/* ]]; then
      skip=1
      break
    fi
  done

  [[ "$skip" -eq 1 ]] && continue

  size_bytes=$(du -s --bytes "$dir" 2>/dev/null | cut -f1)
  [[ -z "$size_bytes" ]] && continue

  size_hr=$(numfmt --to=iec-i --suffix=B "$size_bytes")
  file_count=$(find "$dir" -type f 2>/dev/null | wc -l)
  subdir_count=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

  rel_path="${dir#"$TARGET"/}"
  top_level="${rel_path%%/*}"

  printf "%-10s  %10d  %8d  %-20s  %s\n" "$size_hr" "$file_count" "$subdir_count" "$top_level" "$dir" >> "$TMP_FILE"
done

sort -hrk1 "$TMP_FILE" | head -n "$LIMIT"

rm -f "$TMP_FILE"

