#!/bin/bash
set -euo pipefail

# --- Defaults ---
TARGET_PATH="${1:-$HOME}" # Renamed from TARGET to be more specific
SCAN_DEPTH=4              # Renamed from DEPTH
DISPLAY_LIMIT=30          # Renamed from LIMIT
USE_EXCLUDES=1
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # Was BACKUPKIT_HOME
# Default excludes file path, now uses REPO_ROOT and short hostname
EXCLUDES_FILE_DEFAULT="$REPO_ROOT/config/excludes/$(whoami)@$(hostname -s)"
EXCLUDES_FILE="$EXCLUDES_FILE_DEFAULT" # Actual excludes file to use, may be overridden by flag

# Enable globstar and extglob for advanced matching
shopt -s globstar extglob nullglob

# --- Argument Parsing ---
# Flags can be interspersed with the optional target path argument.
# The first non-option argument encountered will be considered the TARGET_PATH.
potential_target_path=""

# Temporary array to hold arguments that are not processed by this loop
remaining_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --depth=*)
      SCAN_DEPTH="${1#*=}"
      shift
      ;;
    --limit=*)
      DISPLAY_LIMIT="${1#*=}"
      shift
      ;;
    --no-excludes)
      USE_EXCLUDES=0
      shift
      ;;
    --excludes-file=*)
      EXCLUDES_FILE="${1#*=}"
      USE_EXCLUDES=1 # Implicitly enable if a file is specified
      shift
      ;;
    -*) # Unknown flag
      echo "WARN: Unknown option: $1" >&2
      shift
      ;;
    *) # Positional argument
      if [[ -z "$potential_target_path" ]]; then
        potential_target_path="$1"
      else
        # If potential_target_path is already set, this is an unexpected additional positional argument.
        # The original script ignored it; this version will too for sanitization pass.
        # A refactor might make this an error or handle multiple targets if desired.
        echo "WARN: Unexpected argument: $1. Ignoring." >&2
      fi
      shift
      ;;
  esac
done

# Finalize TARGET_PATH: use potential_target_path if set, otherwise stick to initial default ($HOME)
if [[ -n "$potential_target_path" ]]; then
  TARGET_PATH="$potential_target_path"
fi

# --- Script Execution ---
echo "Bloatscan: Scanning directory: $TARGET_PATH"
echo "Bloatscan: Maximum scan depth: $SCAN_DEPTH"
echo "Bloatscan: Displaying top $DISPLAY_LIMIT entries by size."

if [[ "$USE_EXCLUDES" -eq 1 ]]; then
  if [[ -f "$EXCLUDES_FILE" ]]; then
    echo "Bloatscan: Using excludes from: $EXCLUDES_FILE"
  else
    echo "Bloatscan: Exclude file not found (or not specified): $EXCLUDES_FILE. Scanning without specific excludes."
    # USE_EXCLUDES=0 # Optionally, force no excludes if file not found. Original script did not explicitly do this.
                     # For sanitization, keeping original behavior: it would try to read a non-existent file (no error due to check below)
                     # or EXCLUDE_PATTERNS would remain empty.
  fi
else
  echo "Bloatscan: Scanning without user-defined excludes."
fi
echo # blank line

TMP_FILE=$(mktemp)
# Ensure TMP_FILE is removed on exit
trap 'rm -f "$TMP_FILE"' EXIT

printf "%-10s  %10s  %8s  %-20s  %s\n" "Size" "Files" "Dirs" "Top-Level" "Path"

# Read and compile exclude patterns
EXCLUDE_PATTERNS=()
# The check for -f "$EXCLUDES_FILE" is important here
if [[ "$USE_EXCLUDES" -eq 1 && -f "$EXCLUDES_FILE" ]]; then
  while IFS= read -r line; do
    # Remove comments and leading/trailing whitespace
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}" # Trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"  # Trim trailing whitespace
    [[ -z "$line" ]] && continue

    expanded_pattern="${line/#\~/$HOME}" # Expand tilde
    expanded_pattern="${expanded_pattern%/}"   # Remove trailing slash for consistent matching
    EXCLUDE_PATTERNS+=("$expanded_pattern")
  done < "$EXCLUDES_FILE"
fi

# Main scan
# Using find's -prune for excludes is generally more efficient.
# Original script comment: "Sticking to that for minimal change." - this refers to shell loop glob matching.
# The find command itself is for finding directories, then shell loop applies excludes.
find "$TARGET_PATH" -mindepth 1 -maxdepth "$SCAN_DEPTH" -type d \
  \( -path "$TARGET_PATH/.git" -o -path "$TARGET_PATH/.svn" -o -path "$TARGET_PATH/.hg" -o -path "$TARGET_PATH/.bzr" \) -prune \
  -o -print0 2>/dev/null |
  while IFS= read -r -d $'\0' dir_path; do # Renamed 'dir' to 'dir_path' for clarity
    skip_dir=0 # Renamed 'skip' to 'skip_dir'

    # Check against all exclude patterns using glob matching
    for pattern_to_check in "${EXCLUDE_PATTERNS[@]}"; do
      # Ensure pattern_to_check is treated as a glob for the comparison
      if [[ "$dir_path" == $pattern_to_check || "$dir_path"/ == $pattern_to_check/* ]]; then
        skip_dir=1
        break
      fi
    done

    if [[ "$skip_dir" -eq 1 ]]; then
      continue
    fi

    # awk to better grab first field, ensure it's a number
    size_bytes=$(du -s --bytes "$dir_path" 2>/dev/null | awk '{print $1}')
    if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then # Simpler check for numeric
        size_bytes=0
    fi

    size_hr=$(numfmt --to=iec-i --suffix=B --padding=7 "$size_bytes")
    # Count files and subdirectories. Using nullglob helps prevent errors if find returns nothing.
    # The 2>/dev/null suppresses errors from find (e.g. permission denied).
    file_count=$(find "$dir_path" -type f 2>/dev/null | wc -l)
    subdir_count=$(find "$dir_path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    rel_path="${dir_path#"$TARGET_PATH"}"
    rel_path="${rel_path#/}" 
    top_level="${rel_path%%/*}"
    if [[ -z "$top_level" && -n "$rel_path" ]]; then # Handle case where dir is direct child
      top_level="$rel_path"
    fi
    if [[ "$TARGET_PATH" == "$dir_path" ]]; then # Handle case where dir is TARGET_PATH itself
      top_level="." 
    fi

    printf "%-10s  %10d  %8d  %-20s  %s\n" "$size_hr" "$file_count" "$subdir_count" "$top_level" "$dir_path" >> "$TMP_FILE"
  done

if [[ -s "$TMP_FILE" ]]; then # Check if TMP_FILE has data
    sort -hrk1 "$TMP_FILE" | head -n "$DISPLAY_LIMIT"
else
    echo "Bloatscan: No directories found matching criteria or all were excluded."
fi

# rm -f "$TMP_FILE" # Handled by trap
