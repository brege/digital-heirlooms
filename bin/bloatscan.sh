#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Default User Configuration Path ---
USER_HOME_CFG_ROOT="$HOME/.config/$PROJECT_NAME"

# --- Script Defaults & Initial Values ---
TARGET_PATH_ARG="" 
SCAN_DEPTH=4
DISPLAY_LIMIT=30
USE_EXCLUDES=1
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" 
VERBOSE_MODE=false # For verbose output

EXCLUDES_FILE=""

# --- Argument Storage ---
config_dir_arg=""   
excludes_file_arg="" 

# Enable globstar and extglob for advanced matching
shopt -s globstar extglob nullglob

# --- Usage Information ---
print_usage() {
  local hostname_short_for_help="$(hostname -s)"
  local whoami_user_for_help="$(whoami)"
  local ultimate_default_exclude_file="$USER_HOME_CFG_ROOT/excludes/${whoami_user_for_help}@${hostname_short_for_help}.exclude"

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
  echo "                         If --excludes-file is not given, this path will be tried for finding"
  echo "                         an exclude file at '<config_dir>/excludes/\$(whoami)@\$(hostname -s).exclude'."
  echo "  --depth=<num>          Maximum depth to scan into subdirectories (Default: $SCAN_DEPTH)."
  echo "  --limit=<num>          Number of top entries to display (Default: $DISPLAY_LIMIT)."
  echo "  --no-excludes          Do not use any exclude patterns, overriding other exclude options."
  echo "  --excludes-file=<path> Path to a file containing exclude patterns (one per line)."
  echo "                         This overrides all default exclude file lookup mechanisms."
  echo "                         (Default lookup order if no flags: '$ultimate_default_exclude_file',"
  echo "                          then via --config-dir if provided)."
  echo "  --verbose, -v          Enable detailed informational output during script execution."
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
    --verbose|-v) 
      VERBOSE_MODE=true
      shift
      ;;
    -*) 
      echo "ERROR: Unknown option: '$1'." >&2 
      print_usage
      exit 1
      ;;
    *) 
      if [[ -z "$TARGET_PATH_ARG" ]]; then 
        TARGET_PATH_ARG="$1"
      else
        echo "WARN: Unexpected additional argument: '$1'. Ignoring." >&2 
      fi
      shift
      ;;
  esac
done

# --- Finalize Target Path for Scanning ---
TARGET_PATH="$HOME" 
if [[ -n "$TARGET_PATH_ARG" ]]; then
  target_realpath_tmp="" 
  if ! target_realpath_tmp="$(realpath "$TARGET_PATH_ARG" 2>/dev/null)"; then
    echo "ERROR: Invalid target path specified: '$TARGET_PATH_ARG' (realpath resolution failed)." >&2
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
DEFAULT_EXCLUDE_FILENAME="${WHOAMI_USER}@${HOSTNAME_SHORT}.exclude" 

if [[ "$USE_EXCLUDES" -eq 1 ]]; then
  if [[ -n "$excludes_file_arg" ]]; then
    if [[ "$VERBOSE_MODE" == true ]]; then
      echo "INFO: --excludes-file flag provided, attempting to use: '$excludes_file_arg'"
    fi
    excludes_file_realpath_tmp=""
    if ! excludes_file_realpath_tmp="$(realpath "$excludes_file_arg" 2>/dev/null)"; then
        echo "WARN: Invalid path specified with --excludes-file: '$excludes_file_arg' (realpath failed). Scanning without specific excludes." >&2
        USE_EXCLUDES=0 
    else
        EXCLUDES_FILE="$excludes_file_realpath_tmp"
    fi
  elif [[ -n "$config_dir_arg" ]]; then
    if [[ "$VERBOSE_MODE" == true ]]; then
      echo "INFO: --config-dir flag provided ('$config_dir_arg'), deriving excludes path."
    fi
    cfg_dir_realpath_tmp=""
    if ! cfg_dir_realpath_tmp="$(realpath "$config_dir_arg" 2>/dev/null)"; then
        echo "WARN: Invalid path specified with --config-dir: '$config_dir_arg' (realpath failed). Trying user default path for excludes." >&2
    elif [[ ! -d "$cfg_dir_realpath_tmp" ]]; then
        echo "WARN: Path specified with --config-dir is not a directory: '$cfg_dir_realpath_tmp'. Trying user default path for excludes." >&2
    else
        EXCLUDES_FILE="$cfg_dir_realpath_tmp/excludes/$DEFAULT_EXCLUDE_FILENAME"
        if [[ "$VERBOSE_MODE" == true ]]; then
          echo "INFO: Checking for excludes file at derived path: '$EXCLUDES_FILE'"
        fi
        mkdir -p "$(dirname "$EXCLUDES_FILE")" 2>/dev/null || true
    fi
  fi

  if [[ "$USE_EXCLUDES" -eq 1 && -z "$EXCLUDES_FILE" ]]; then 
    if [[ "$VERBOSE_MODE" == true ]]; then
      echo "INFO: No --excludes-file or valid --config-dir for excludes. Attempting user default path for excludes."
    fi
    EXCLUDES_FILE="$USER_HOME_CFG_ROOT/excludes/$DEFAULT_EXCLUDE_FILENAME"
    if [[ "$VERBOSE_MODE" == true ]]; then
      echo "INFO: Checking for excludes file at user default path: '$EXCLUDES_FILE'"
    fi
    mkdir -p "$(dirname "$EXCLUDES_FILE")" 2>/dev/null || true
  fi

  if [[ "$USE_EXCLUDES" -eq 1 && -n "$EXCLUDES_FILE" && ! -f "$EXCLUDES_FILE" ]]; then
    echo "INFO: Exclude file specified or derived does not exist: '$EXCLUDES_FILE'."
  fi
else
  EXCLUDES_FILE="" 
fi

# --- Script Execution Initial Output ---
echo "Bloatscan: Scanning directory: '$TARGET_PATH'"
echo "Bloatscan: Maximum scan depth: $SCAN_DEPTH"
echo "Bloatscan: Displaying top $DISPLAY_LIMIT entries by size."

# --- Report Exclude File Status ---
if [[ "$USE_EXCLUDES" -eq 1 && -n "$EXCLUDES_FILE" && -f "$EXCLUDES_FILE" ]]; then
  echo "Bloatscan: Using excludes from: '$EXCLUDES_FILE'"
elif [[ "$USE_EXCLUDES" -eq 1 ]]; then 
  echo "Bloatscan: Exclude file was not found or not specified. Scanning without specific excludes."
  USE_EXCLUDES=0 
else 
  echo "Bloatscan: Scanning without any user-defined excludes."
fi
echo # Blank line for readability

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
find "$TARGET_PATH" -mindepth 1 -maxdepth "$SCAN_DEPTH" -type d \
  \( -path "$TARGET_PATH/.git" -o -path "$TARGET_PATH/.svn" -o -path "$TARGET_PATH/.hg" -o -path "$TARGET_PATH/.bzr" \) -prune \
  -o -print0 2>/dev/null |
  while IFS= read -r -d $'\0' dir_path; do
    skip_dir=0
    for pattern_to_check in "${EXCLUDE_PATTERNS[@]}"; do
      if [[ "$dir_path" == $pattern_to_check || "$dir_path"/ == $pattern_to_check/* ]]; then
        skip_dir=1
        if [[ "$VERBOSE_MODE" == true ]]; then
          echo "INFO: Directory '$dir_path' skipped due to exclude pattern: '$pattern_to_check'"
        fi
        break
      fi
    done

    if [[ "$skip_dir" -eq 1 ]]; then
      continue
    fi

    size_bytes_str=""
    size_bytes_str=$(du -s --bytes "$dir_path" 2>/dev/null | awk '{print $1}') 
    if [[ ! "$size_bytes_str" =~ ^[0-9]+$ ]]; then
        echo "WARN: Could not determine size for directory '$dir_path'. Assigning size 0." >&2
        size_bytes=0
    else
        size_bytes=$size_bytes_str
    fi

    size_hr=$(numfmt --to=iec-i --suffix=B --padding=7 "$size_bytes")
    
    file_count=$(find "$dir_path" -maxdepth 1 -type f -printf '.' 2>/dev/null | wc -c)
    rc_file_count=$?

    subdir_count=$(find "$dir_path" -mindepth 1 -maxdepth 1 -type d -printf '.' 2>/dev/null | wc -c)
    rc_subdir_count=$?

    if [[ $rc_file_count -ne 0 || $rc_subdir_count -ne 0 ]]; then
        echo "WARN: Could not accurately determine file/subdir counts for '$dir_path' due to find errors. Results for this entry may be incomplete." >&2
    fi

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
if [[ -s "$TMP_FILE" ]]; then 
    sort -hrk1 "$TMP_FILE" | head -n "$DISPLAY_LIMIT"
else
    echo "Bloatscan: No directories found matching criteria or all were excluded."
fi
