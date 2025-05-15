#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Default User Configuration Path ---
USER_HOME_CFG_ROOT="$HOME/.config/$PROJECT_NAME"

# --- Script Defaults & Initial Values ---
TARGET_PATH_ARG="" # To store positional path argument
SCAN_DEPTH=4
DISPLAY_LIMIT=30
USE_EXCLUDES=1
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# EXCLUDES_FILE will be determined after argument parsing
EXCLUDES_FILE=""

# --- Argument Storage ---
config_dir_arg=""   # Stores value from --config-dir
excludes_file_arg="" # Stores value from --excludes-file

# Enable globstar and extglob for advanced matching
shopt -s globstar extglob nullglob

# --- Usage Information ---
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
  echo "                         If --excludes-file is not given, this path will be used to"
  echo "                         look for '<config_dir>/excludes/\$(whoami)@\$(hostname -s)'."
  echo "                         (Standard user config default for other scripts: $USER_HOME_CFG_ROOT)"
  echo "  --depth=<num>          Maximum depth to scan into subdirectories (Default: $SCAN_DEPTH)."
  echo "  --limit=<num>          Number of top entries to display (Default: $DISPLAY_LIMIT)."
  echo "  --no-excludes          Do not use any exclude patterns."
  echo "  --excludes-file=<path> Path to a file containing exclude patterns (one per line)."
  echo "                         Overrides default exclude file lookup."
  echo "                         (Default if no other options: $USER_HOME_CFG_ROOT/excludes/\$(whoami)@\$(hostname -s))"
  echo "  --help, -h             Show this help message."
}

# --- Argument Parsing ---
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
      excludes_file_arg="${1#*=}" 
      USE_EXCLUDES=1 
      shift
      ;;
    -*) 
      echo "ERROR: Unknown option: $1" >&2
      print_usage
      exit 1
      ;;
    *) 
      if [[ -z "$TARGET_PATH_ARG" ]]; then 
        TARGET_PATH_ARG="$1"
      else
        echo "WARN: Unexpected argument: $1. Ignoring." >&2
      fi
      shift
      ;;
  esac
done

# --- Finalize Target Path for Scanning ---
TARGET_PATH="$HOME" 
if [[ -n "$TARGET_PATH_ARG" ]]; then
  if ! target_realpath_tmp="$(realpath "$TARGET_PATH_ARG" 2>/dev/null)"; then
    echo "ERROR: Invalid target path specified: '$TARGET_PATH_ARG' (realpath failed)." >&2
    exit 1
  fi
  if [[ ! -d "$target_realpath_tmp" ]]; then
    echo "ERROR: Target path '$target_realpath_tmp' is not a directory." >&2
    exit 1
  fi
  TARGET_PATH="$target_realpath_tmp"
fi


# --- Determine and Validate Excludes File Path ---
HOSTNAME_SHORT="$(hostname -s)"
WHOAMI_USER="$(whoami)"
DEFAULT_EXCLUDE_FILENAME="${WHOAMI_USER}@${HOSTNAME_SHORT}" 

if [[ "$USE_EXCLUDES" -eq 1 ]]; then
  if [[ -n "$excludes_file_arg" ]]; then
    # Priority 1: --excludes-file flag
    echo "INFO: --excludes-file flag provided."
    if ! excludes_file_realpath_tmp="$(realpath "$excludes_file_arg" 2>/dev/null)"; then
        echo "WARN: Invalid path specified with --excludes-file: '$excludes_file_arg' (realpath failed). Scanning without excludes." >&2
        USE_EXCLUDES=0 
    else
        EXCLUDES_FILE="$excludes_file_realpath_tmp"
    fi
  elif [[ -n "$config_dir_arg" ]]; then
    # Priority 2: --config-dir flag
    echo "INFO: --config-dir flag provided, deriving excludes path."
    cfg_dir_realpath_tmp=""
    if ! cfg_dir_realpath_tmp="$(realpath "$config_dir_arg" 2>/dev/null)"; then
        echo "WARN: Invalid path specified with --config-dir: '$config_dir_arg' (realpath failed). Trying user default path." >&2
    elif [[ ! -d "$cfg_dir_realpath_tmp" ]]; then
        echo "WARN: Path specified with --config-dir is not a directory: '$cfg_dir_realpath_tmp'. Trying user default path." >&2
    else
        EXCLUDES_FILE="$cfg_dir_realpath_tmp/excludes/$DEFAULT_EXCLUDE_FILENAME"
        mkdir -p "$(dirname "$EXCLUDES_FILE")" 2>/dev/null || true
    fi
  fi

  # Priority 3: User-centric default (if EXCLUDES_FILE still not set and USE_EXCLUDES is still 1)
  if [[ "$USE_EXCLUDES" -eq 1 && -z "$EXCLUDES_FILE" ]]; then 
    echo "INFO: No --excludes-file or valid --config-dir for excludes. Using user default path."
    EXCLUDES_FILE="$USER_HOME_CFG_ROOT/excludes/$DEFAULT_EXCLUDE_FILENAME"
    mkdir -p "$(dirname "$EXCLUDES_FILE")" 2>/dev/null || true
  fi

  # Final check if an exclude file path was determined (but not necessarily if it exists yet)
  if [[ "$USE_EXCLUDES" -eq 1 && -n "$EXCLUDES_FILE" && ! -f "$EXCLUDES_FILE" ]]; then
    echo "INFO: Exclude file specified or derived does not exist: $EXCLUDES_FILE"
  fi
else
  EXCLUDES_FILE="" 
fi


# --- Script Execution Initial Output ---
echo "Bloatscan: Scanning directory: $TARGET_PATH"
echo "Bloatscan: Maximum scan depth: $SCAN_DEPTH"
echo "Bloatscan: Displaying top $DISPLAY_LIMIT entries by size."

# --- Report Exclude File Status ---
if [[ "$USE_EXCLUDES" -eq 1 && -n "$EXCLUDES_FILE" && -f "$EXCLUDES_FILE" ]]; then
  echo "Bloatscan: Using excludes from: $EXCLUDES_FILE"
elif [[ "$USE_EXCLUDES" -eq 1 ]]; then 
  echo "Bloatscan: Exclude file was not found or not specified. Scanning without specific excludes."
  USE_EXCLUDES=0 # Force off if file is unusable or path is empty
else
  echo "Bloatscan: Scanning without user-defined excludes."
fi
echo

# --- Setup Temporary File and Cleanup Trap ---
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

# --- Print Results Header ---
printf "%-10s  %10s  %8s  %-20s  %s\n" "Size" "Files" "Dirs" "Top-Level" "Path"

# --- Read and Compile Exclude Patterns (if applicable) ---
EXCLUDE_PATTERNS=()
if [[ "$USE_EXCLUDES" -eq 1 && -n "$EXCLUDES_FILE" && -f "$EXCLUDES_FILE" ]]; then
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

# --- Perform Main Directory Scan and Data Collection ---
# Using find to locate directories, then shell loop applies custom excludes and gathers stats.
find "$TARGET_PATH" -mindepth 1 -maxdepth "$SCAN_DEPTH" -type d \
  \( -path "$TARGET_PATH/.git" -o -path "$TARGET_PATH/.svn" -o -path "$TARGET_PATH/.hg" -o -path "$TARGET_PATH/.bzr" \) -prune \
  -o -print0 2>/dev/null |
  while IFS= read -r -d $'\0' dir_path; do
    skip_dir=0
    # Check against all exclude patterns using glob matching
    for pattern_to_check in "${EXCLUDE_PATTERNS[@]}"; do
      if [[ "$dir_path" == $pattern_to_check || "$dir_path"/ == $pattern_to_check/* ]]; then
        skip_dir=1
        break
      fi
    done

    if [[ "$skip_dir" -eq 1 ]]; then
      continue
    fi

    # Gather directory statistics
    size_bytes=$(du -s --bytes "$dir_path" 2>/dev/null | awk '{print $1}')
    if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then # Ensure numeric if du fails
        size_bytes=0
    fi
    size_hr=$(numfmt --to=iec-i --suffix=B --padding=7 "$size_bytes")
    file_count=$(find "$dir_path" -maxdepth 1 -type f 2>/dev/null | wc -l) # Count only files directly in dir_path
    subdir_count=$(find "$dir_path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) # Count only subdirs directly in dir_path

    # Determine relative and top-level path components for display
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

# --- Sort and Display Final Results ---
if [[ -s "$TMP_FILE" ]]; then # Check if TMP_FILE has data
    sort -hrk1 "$TMP_FILE" | head -n "$DISPLAY_LIMIT"
else
    echo "Bloatscan: No directories found matching criteria or all were excluded."
fi
# Note: rm -f "$TMP_FILE" is handled by trap
