#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Default User Configuration (for print_usage & future use) ---
USER_CONFIG_DEFAULT="$HOME/.config/$PROJECT_NAME"

# --- Defaults ---
TARGET_PATH="${1:-$HOME}" # Will be properly set via potential_target_path after parsing
SCAN_DEPTH=4
DISPLAY_LIMIT=30
USE_EXCLUDES=1
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Default excludes file path, may be influenced by --config-dir in future themes
EXCLUDES_FILE_DEFAULT="$REPO_ROOT/config/excludes/$(whoami)@$(hostname -s)"
EXCLUDES_FILE="$EXCLUDES_FILE_DEFAULT" # Actual excludes file to use

# --- Argument Storage ---
config_dir_arg="" # Stores value from --config-dir

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
  echo "  --config-dir <path>    Specify a root directory for project configurations."
  echo "                         (May influence default for --excludes-file if not set directly)."
  echo "                         (Standard user config default: $USER_CONFIG_DEFAULT)"
  echo "  --depth=<num>          Maximum depth to scan into subdirectories (Default: $SCAN_DEPTH)."
  echo "  --limit=<num>          Number of top entries to display (Default: $DISPLAY_LIMIT)."
  echo "  --no-excludes          Do not use any exclude patterns."
  echo "  --excludes-file=<path> Path to a file containing exclude patterns (one per line)."
  echo "                         (Default: $EXCLUDES_FILE_DEFAULT)"
  echo "  --help, -h             Show this help message."
}

# --- Argument Parsing ---
potential_target_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      print_usage
      exit 0
      ;;
    --config-dir=*)
      config_dir_arg="${1#*=}"
      shift
      ;;
    --config-dir)
      if [[ -n "${2:-}" && "${2}" != --* ]]; then
        config_dir_arg="$2"
        shift 2
      else
        echo "ERROR: --config-dir requires a value." >&2
        print_usage
        exit 1
      fi
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
      USE_EXCLUDES=1 
      shift
      ;;
    -*) 
      echo "ERROR: Unknown option: $1" >&2
      print_usage
      exit 1
      ;;
    *) 
      if [[ -z "$potential_target_path" ]]; then
        potential_target_path="$1"
      else
        echo "WARN: Unexpected argument: $1. Ignoring." >&2
      fi
      shift
      ;;
  esac
done

if [[ -n "$potential_target_path" ]]; then
  TARGET_PATH="$potential_target_path"
elif [[ -z "${1:-}" && -z "$potential_target_path" ]]; then 
  TARGET_PATH="$HOME" 
fi

# Note: config_dir_arg is parsed but not yet used to change EXCLUDES_FILE logic in Theme 2.
# That change (Flexible Exclude File Configuration) is part of Theme 3 (BS.B).

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
trap 'rm -f "$TMP_FILE"' EXIT

printf "%-10s  %10s  %8s  %-20s  %s\n" "Size" "Files" "Dirs" "Top-Level" "Path"

EXCLUDE_PATTERNS=()
if [[ "$USE_EXCLUDES" -eq 1 && -f "$EXCLUDES_FILE" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}" 
    line="${line%"${line##*[![:space:]]}"}"  
    [[ -z "$line" ]] && continue
    expanded_pattern="${line/#\~/$HOME}"
    expanded_pattern="${expanded_pattern%/}"
    EXCLUDE_PATTERNS+=("$expanded_pattern")
  done < "$EXCLUDES_FILE"
fi

find "$TARGET_PATH" -mindepth 1 -maxdepth "$SCAN_DEPTH" -type d \
  \( -path "$TARGET_PATH/.git" -o -path "$TARGET_PATH/.svn" -o -path "$TARGET_PATH/.hg" -o -path "$TARGET_PATH/.bzr" \) -prune \
  -o -print0 2>/dev/null |
  while IFS= read -r -d $'\0' dir_path; do
    skip_dir=0
    for pattern_to_check in "${EXCLUDE_PATTERNS[@]}"; do
      if [[ "$dir_path" == $pattern_to_check || "$dir_path"/ == $pattern_to_check/* ]]; then
        skip_dir=1
        break
      fi
    done

    if [[ "$skip_dir" -eq 1 ]]; then
      continue
    fi

    size_bytes=$(du -s --bytes "$dir_path" 2>/dev/null | awk '{print $1}')
    if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then
        size_bytes=0
    fi

    size_hr=$(numfmt --to=iec-i --suffix=B --padding=7 "$size_bytes")
    file_count=$(find "$dir_path" -type f 2>/dev/null | wc -l)
    subdir_count=$(find "$dir_path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    rel_path="${dir_path#"$TARGET_PATH"}"
    rel_path="${rel_path#/}"
    top_level="${rel_path%%/*}"
    if [[ -z "$top_level" && -n "$rel_path" ]]; then
      top_level="$rel_path"
    fi
    if [[ "$TARGET_PATH" == "$dir_path" ]]; then
      top_level="."
    fi

    printf "%-10s  %10d  %8d  %-20s  %s\n" "$size_hr" "$file_count" "$subdir_count" "$top_level" "$dir_path" >> "$TMP_FILE"
  done

if [[ -s "$TMP_FILE" ]]; then
    sort -hrk1 "$TMP_FILE" | head -n "$DISPLAY_LIMIT"
else
    echo "Bloatscan: No directories found matching criteria or all were excluded."
fi
