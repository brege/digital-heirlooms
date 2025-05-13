#!/bin/bash

# Defaults
TARGET="${1:-$HOME}"
DEPTH=4
LIMIT=30
USE_EXCLUDES=1
# Corrected EXCLUDES_FILE path to be relative to BACKUPKIT_HOME for robustness
BACKUPKIT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXCLUDES_FILE="$BACKUPKIT_HOME/config/excludes/$(whoami)@$(hostname)" # Assumes user@hostname format for excludes

# Enable globstar and extglob for advanced matching
shopt -s globstar extglob nullglob

# Parse flags
# Reset TARGET if arguments are present, so flags are processed correctly
# and the first non-flag argument becomes the TARGET.
# If only flags are present, TARGET remains its default or previous value.
potential_target=""
processed_args=() # Store processed arguments to rebuild $@ if needed

while [[ $# -gt 0 ]]; do
  case "$1" in
    --depth=*)
      DEPTH="${1#*=}"
      processed_args+=("$1") # Keep it for arg rebuilding if TARGET was not set yet
      shift
      ;;
    --limit=*)
      LIMIT="${1#*=}"
      processed_args+=("$1")
      shift
      ;;
    --no-excludes)
      USE_EXCLUDES=0
      processed_args+=("$1")
      shift
      ;;
    --excludes-file=*)
      EXCLUDES_FILE="${1#*=}"
      USE_EXCLUDES=1 # Implicitly enable if a file is specified
      processed_args+=("$1")
      shift
      ;;
    -*) # Unknown flag
      echo "[WARN] Unknown option: $1"
      processed_args+=("$1")
      shift
      ;;
    *) # This should be the TARGET path
      if [[ -z "$potential_target" ]]; then # Only take the first non-flag argument as TARGET
        potential_target="$1"
      else
        # If potential_target is already set, this is an unexpected positional argument
        echo "[WARN] Unexpected argument: $1. Ignoring."
      fi
      shift # Always shift after processing or identifying an argument
      ;;
  esac
done

# If potential_target was found, use it. Otherwise, keep the default.
if [[ -n "$potential_target" ]]; then
  TARGET="$potential_target"
elif [[ "${processed_args[0]}" == "$TARGET" && "$TARGET" == "$HOME" ]]; then
  # If TARGET is still default $HOME and no other path was given, it's fine.
  # If arguments were only flags, TARGET remains default.
  : # No change needed for TARGET
else
  # If no positional argument was provided for TARGET, and it's not default,
  # it might mean an issue or user intended default.
  # For safety, if TARGET was part of initial args and it's not default, re-check logic.
  # Current logic: first non-flag is TARGET. If none, default.
  :
fi


echo "Bloatscan: Scanning directory: $TARGET"
echo "Bloatscan: Maximum scan depth: $DEPTH"
echo "Bloatscan: Displaying top $LIMIT entries by size."
if [[ "$USE_EXCLUDES" == "1" && -f "$EXCLUDES_FILE" ]]; then
  echo "Bloatscan: Using excludes from: $EXCLUDES_FILE"
elif [[ "$USE_EXCLUDES" == "1" ]]; then
  echo "Bloatscan: Exclude file not found (or not specified): $EXCLUDES_FILE. Scanning without specific excludes."
else
  echo "Bloatscan: Scanning without user-defined excludes."
fi
echo # blank line

TMP_FILE=$(mktemp)
# Ensure TMP_FILE is removed on exit
trap 'rm -f "$TMP_FILE"' EXIT

printf "%-10s  %10s  %8s  %-20s  %s\n" "Size" "Files" "Dirs" "Top-Level" "Path"

# Read and compile exclude patterns
EXCLUDE_PATTERNS=() # Renamed to avoid conflict with find's -prune -o -print -name pattern
if [[ "$USE_EXCLUDES" == "1" && -f "$EXCLUDES_FILE" ]]; then
  while IFS= read -r line; do
    # Remove comments and leading/trailing whitespace
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    # Convert glob patterns to be more compatible with string matching if needed,
    # or ensure find -path -prune is used.
    # For simple string prefix matching as in original:
    expanded_pattern="${line/#\~/$HOME}" # Expand tilde
    expanded_pattern="${expanded_pattern%/}"   # Remove trailing slash for consistent matching
    EXCLUDE_PATTERNS+=("$expanded_pattern")
  done < "$EXCLUDES_FILE"
fi

# Main scan
# Using find's -prune for excludes is generally more efficient than checking in a loop.
# However, the original script used shell loop glob matching. Sticking to that for minimal change.
find "$TARGET" -mindepth 1 -maxdepth "$DEPTH" -type d \( -path "$TARGET/.git" -o -path "$TARGET/.svn" -o -path "$TARGET/.hg" -o -path "$TARGET/.bzr" \) -prune -o -print0 2>/dev/null | while IFS= read -r -d $'\0' dir; do
  skip=0

  # Check against all exclude patterns using glob matching
  for pattern_to_check in "${EXCLUDE_PATTERNS[@]}"; do # Use the renamed array
    # Ensure pattern_to_check is treated as a glob for the comparison
    if [[ "$dir" == $pattern_to_check || "$dir"/ == $pattern_to_check/* ]]; then
      skip=1
      break
    fi
  done

  [[ "$skip" -eq 1 ]] && continue

  size_bytes=$(du -s --bytes "$dir" 2>/dev/null | awk '{print $1}') # awk to better grab first field
  [[ -z "$size_bytes" || ! "$size_bytes" =~ ^[0-9]+$ ]] && size_bytes=0 # Ensure it's a number

  size_hr=$(numfmt --to=iec-i --suffix=B --padding=7 "$size_bytes") # padding for alignment
  file_count=$(find "$dir" -type f 2>/dev/null | wc -l)
  subdir_count=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

  rel_path="${dir#"$TARGET"}"
  rel_path="${rel_path#/}" # Remove leading / if TARGET was /
  top_level="${rel_path%%/*}"
  [[ -z "$top_level" && -n "$rel_path" ]] && top_level="$rel_path" # Handle case where dir is direct child
  [[ "$TARGET" == "$dir" ]] && top_level="." # Handle case where dir is TARGET itself (though mindepth 1)


  printf "%-10s  %10d  %8d  %-20s  %s\n" "$size_hr" "$file_count" "$subdir_count" "$top_level" "$dir" >> "$TMP_FILE"
done

if [[ -s "$TMP_FILE" ]]; then # Check if TMP_FILE has data
    sort -hrk1 "$TMP_FILE" | head -n "$LIMIT"
else
    echo "Bloatscan: No directories found matching criteria or all were excluded."
fi

# rm -f "$TMP_FILE" # Handled by trap
