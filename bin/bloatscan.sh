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
QUIET_MODE=false # Theme 5: Flag for quiet mode

EXCLUDES_FILE=""

# --- Argument Storage ---
config_dir_arg=""   
excludes_file_arg="" 

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
  echo "  --quiet, -q            Suppress informational output; only show results or errors."
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
    --quiet|-q) # Theme 5: Added quiet mode
      QUIET_MODE=true
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
    if [[ "$QUIET_MODE" == false ]]; then echo "INFO: --excludes-file flag provided."; fi
    if ! excludes_file_realpath_tmp="$(realpath "$excludes_file_arg" 2>/dev/null)"; then
        echo "WARN: Invalid path specified with --excludes-file: '$excludes_file_arg' (realpath failed). Scanning without excludes." >&2
        USE_EXCLUDES=0 
    else
        EXCLUDES_FILE="$excludes_file_realpath_tmp"
    fi
  elif [[ -n "$config_dir_arg" ]]; then
    # Priority 2: --config-dir flag
    if [[ "$QUIET_MODE" == false ]]; then echo "INFO: --config-dir flag provided, deriving excludes path."; fi
    cfg_dir_realpath_tmp=""
    if ! cfg_dir_realpath_tmp="$(realpath "$config_dir_arg" 2>/dev/null)"; then
        echo "WARN: Invalid path specified with --config-dir: '$config_dir_arg' (realpath failed). Trying user default path." >&2
    elif [[ ! -d "$cfg_dir_realpath_tmp" ]]; then
        echo "WARN: Path specified with --config-dir is not a directory: '$cfg_dir_realpath_tmp'. Trying user default path." >&2
    else
        EXCLUDES_FILE="$cfg_dir_realpath_tmp/excludes/$DEFAULT_EXCLUDE_FILENAME"
        # Attempt to create parent directory for convenience, siloing errors
        mkdir -p "$(dirname "$EXCLUDES_FILE")" 2>/dev/null || true
    fi
  fi

  # Priority 3: User-centric default (if EXCLUDES_FILE still not set and USE_EXCLUDES is still 1)
  if [[ "$USE_EXCLUDES" -eq 1 && -z "$EXCLUDES_FILE" ]]; then 
    if [[ "$QUIET_MODE" == false ]]; then echo "INFO: No --excludes-file or valid --config-dir for excludes. Using user default path."; fi
    EXCLUDES_FILE="$USER_HOME_CFG_ROOT/excludes/$DEFAULT_EXCLUDE_FILENAME"
    mkdir -p "$(dirname "$EXCLUDES_FILE")" 2>/dev/null || true
  fi

  if [[ "$USE_EXCLUDES" -eq 1 && -n "$EXCLUDES_FILE" && ! -f "$EXCLUDES_FILE" ]]; then
    # This specific INFO message is useful even in quiet mode if excludes were intended but file missing.
    echo "INFO: Exclude file specified or derived does not exist: $EXCLUDES_FILE"
  fi
else
  EXCLUDES_FILE="" 
fi


# --- Script Execution Initial Output ---
if [[ "$QUIET_MODE" == false ]]; then
  echo "Bloatscan: Scanning directory: $TARGET_PATH"
  echo "Bloatscan: Maximum scan depth: $SCAN_DEPTH"
  echo "Bloatscan: Displaying top $DISPLAY_LIMIT entries by size."
fi

# --- Report Exclude File Status ---
if [[ "$USE_EXCLUDES" -eq 1 && -n "$EXCLUDES_FILE" && -f "$EXCLUDES_FILE" ]]; then
  if [[ "$QUIET_MODE" == false ]]; then echo "Bloatscan: Using excludes from: $EXCLUDES_FILE"; fi
elif [[ "$USE_EXCLUDES" -eq 1 ]]; then 
  if [[ "$QUIET_MODE" == false ]]; then echo "Bloatscan: Exclude file was not found or not specified. Scanning without specific excludes."; fi
  USE_EXCLUDES=0 
else
  if [[ "$QUIET_MODE" == false ]]; then echo "Bloatscan: Scanning without user-defined excludes."; fi
fi
if [[ "$QUIET_MODE" == false ]]; then echo; fi # Blank line for readability if not quiet

# --- Setup Temporary File and Cleanup Trap ---
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

# --- Print Results Header ---
# Header should always print, even in quiet mode
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
  -o -print0 2>/dev/null | # Suppress find's own errors about unreadable directories here
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

    # Gather directory statistics
    size_bytes_str=""
    size_bytes_str=$(du -s --bytes "$dir_path" 2>/dev/null | awk '{print $1}') 
    # Theme 5: Check exit status of du (though awk might mask it if du outputs nothing)
    # A more robust check might involve `du ... || echo "ERROR_DU"` and checking output.
    # For now, keeping simple check on output.
    if [[ ! "$size_bytes_str" =~ ^[0-9]+$ ]]; then
        # This can happen if du has an error and outputs nothing, or outputs an error message.
        echo "WARN: Could not determine size for directory '$dir_path'. Assigning size 0." >&2
        size_bytes=0
    else
        size_bytes=$size_bytes_str
    fi

    size_hr=$(numfmt --to=iec-i --suffix=B --padding=7 "$size_bytes")
    
    # Using temporary files for counts to check their exit codes more easily
    temp_file_count_file=$(mktemp)
    temp_subdir_count_file=$(mktemp)

    find "$dir_path" -maxdepth 1 -type f -print0 2>/dev/null | tr -d '\0' | wc -c > "$temp_file_count_file"
    # find ... -print0 | wc -c with null delimiter is not standard for line count. Use xargs.
    # find "$dir_path" -maxdepth 1 -type f -print0 2>/dev/null | xargs -0 printf "%s\n" | wc -l > "$temp_file_count_file"
    # Simpler:
    file_count=$(find "$dir_path" -maxdepth 1 -type f -printf '.' 2>/dev/null | wc -c)
    rc_file_count=$?

    subdir_count=$(find "$dir_path" -mindepth 1 -maxdepth 1 -type d -printf '.' 2>/dev/null | wc -c)
    rc_subdir_count=$?

    rm -f "$temp_file_count_file" "$temp_subdir_count_file" # Clean up temp files for counts

    if [[ $rc_file_count -ne 0 || $rc_subdir_count -ne 0 ]]; then
        echo "WARN: Could not accurately determine file/subdir counts for '$dir_path' due to find errors." >&2
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
    # This message is important even in quiet mode if no results.
    echo "Bloatscan: No directories found matching criteria or all were excluded."
fi
