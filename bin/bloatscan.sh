#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Defaults ---
TARGET_PATH="${1:-$HOME}" # Will be properly set via potential_target_path after parsing
SCAN_DEPTH=4
DISPLAY_LIMIT=30
USE_EXCLUDES=1
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Default excludes file path, now uses REPO_ROOT and short hostname
EXCLUDES_FILE_DEFAULT="$REPO_ROOT/config/excludes/$(whoami)@$(hostname -s)"
EXCLUDES_FILE="$EXCLUDES_FILE_DEFAULT" # Actual excludes file to use, may be overridden by flag

# Enable globstar and extglob for advanced matching
shopt -s globstar extglob nullglob

print_usage() {
  echo "Usage: $0 [OPTIONS] [target_path]"
  echo ""
  echo "Scans a directory to identify large subdirectories ('bloat')."
  echo "Results are sorted by size, largest first."
  echo ""
  echo "Arguments:"
  echo "  [target_path]          The directory to scan. Defaults to \$HOME if not specified."
  echo ""
  echo "Options:"
  echo "  --depth=<num>          Maximum depth to scan into subdirectories (Default: $SCAN_DEPTH)."
  echo "  --limit=<num>          Number of top entries to display (Default: $DISPLAY_LIMIT)."
  echo "  --no-excludes          Do not use any exclude patterns."
  echo "  --excludes-file=<path> Path to a file containing exclude patterns (one per line)."
  echo "                         (Default: $EXCLUDES_FILE_DEFAULT or as per --config-dir in later themes)"
  echo "  --help, -h             Show this help message."
}

# --- Argument Parsing ---
# Flags can be interspersed with the optional target path argument.
# The first non-option argument encountered will be considered the TARGET_PATH.
potential_target_path="" # Intentionally not pre-filling with $1 here

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      print_usage
      exit 0
      ;;
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
      echo "ERROR: Unknown option: $1" >&2
      print_usage
      exit 1
      ;;
    *) # Positional argument
      if [[ -z "$potential_target_path" ]]; then
        potential_target_path="$1"
      else
        # If potential_target_path is already set, this is an unexpected additional positional argument.
        # The original script ignored it with a warning; maintaining that behavior.
        echo "WARN: Unexpected argument: $1. Ignoring." >&2
      fi
      shift
      ;;
  esac
done

# Finalize TARGET_PATH: use potential_target_path if set, otherwise stick to initial default ($HOME)
if [[ -n "$potential_target_path" ]]; then
  TARGET_PATH="$potential_target_path"
elif [[ -z "${1:-}" && -z "$potential_target_path" ]]; then # If $1 was never processed and no potential_target_path set
  TARGET_PATH="$HOME" # Explicitly set to $HOME if no path arg was ever given
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
  fi
else
  echo "Bloatscan: Scanning without user-defined excludes."
fi
echo

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
    line="${line#"${line%%[![:space:]]*}"}" 
    line="${line%"${line##*[![:space:]]}"}"  
    [[ -z "$line" ]] && continue

    # Expand tilde
    expanded_pattern="${line/#\~/$HOME}"
    # Remove trailing slash for consistent matching
    expanded_pattern="${expanded_pattern%/}"
    EXCLUDE_PATTERNS+=("$expanded_pattern")
  done < "$EXCLUDES_FILE"
fi

# Main scan
# Using find's -prune for excludes is generally more efficient.
# This script uses shell loop glob matching for excludes after find identifies directories.
find "$TARGET_PATH" -mindepth 1 -maxdepth "$SCAN_DEPTH" -type d \
  \( -path "$TARGET_PATH/.git" -o -path "$TARGET_PATH/.svn" -o -path "$TARGET_PATH/.hg" -o -path "$TARGET_PATH/.bzr" \) -prune \
  -o -print0 2>/dev/null |
  while IFS= read -r -d $'\0' dir_path; do
    skip_dir=0

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
    if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then
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
