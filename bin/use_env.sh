#!/bin/bash

set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Default User Configuration & Paths ---
USER_CONFIG_DEFAULT="$HOME/.config/$PROJECT_NAME"
ENV_FILES_SUBDIR="env" # Standard subdirectory for environment files

EFFECTIVE_CONFIG_DIR=""

# --- Argument Storage ---
ENV_ARG_CAPTURED=""
CONFIG_DIR_ARG=""

print_usage() {
  echo "Usage: $0 [OPTIONS] <env_file_name_or_path>"
  echo ""
  echo "Sets the active backup environment for '$PROJECT_NAME' by creating a symlink"
  echo "named 'backup.env' in the relevant configuration directory."
  echo ""
  echo "Arguments:"
  echo "  <env_file_name_or_path>  The name of the environment file (e.g., my_profile.env)"
  echo "                           or an absolute/relative path to an environment file."
  echo ""
  echo "Options:"
  echo "  --config-dir <path>      Specify the root directory for '$PROJECT_NAME' user configurations."
  echo "                           Affects where 'backup.env' is placed and where env files are sought by default."
  echo "                           (Default if not specified, and used by other scripts: $USER_CONFIG_DEFAULT)"
  echo "  --help, -h               Show this help message."
  echo ""
  echo "Examples:"
  echo "  $0 my_profile.env"
  echo "  $0 path/to/custom/location/another_profile.env"
  echo "  $0 --config-dir /mnt/myconfigs/$PROJECT_NAME special_setup.env"
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --config-dir=*)
      CONFIG_DIR_ARG="${arg#*=}"
      shift
      ;;
    --config-dir)
      if [[ -n "${2:-}" && "${2}" != --* ]]; then
        CONFIG_DIR_ARG="$2"
        shift 2
      else
        echo "ERROR: --config-dir requires a value." >&2
        print_usage
        exit 1
      fi
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $arg" >&2
      print_usage
      exit 1
      ;;
    *)
      if [[ -z "$ENV_ARG_CAPTURED" ]]; then
        ENV_ARG_CAPTURED="$arg"
      else
        echo "ERROR: Too many arguments. Expected a single environment file name or path." >&2
        print_usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$ENV_ARG_CAPTURED" ]]; then
  echo "ERROR: No environment file specified." >&2
  print_usage
  exit 1
fi

# --- Determine Effective Configuration Directory ---
if [[ -n "$CONFIG_DIR_ARG" ]]; then
  EFFECTIVE_CONFIG_DIR="$CONFIG_DIR_ARG"
else
  EFFECTIVE_CONFIG_DIR="$USER_CONFIG_DEFAULT"
fi

# --- Validate and Resolve EFFECTIVE_CONFIG_DIR ---
cfg_dir_original_value="$EFFECTIVE_CONFIG_DIR"
if ! config_dir_realpath_tmp="$(realpath "$EFFECTIVE_CONFIG_DIR" 2>/dev/null)"; then
    echo "ERROR: Invalid path specified for configuration directory: $cfg_dir_original_value" >&2
    echo "       Please ensure the path is correct and accessible." >&2
    exit 1
fi
EFFECTIVE_CONFIG_DIR="$config_dir_realpath_tmp"

if [[ ! -d "$EFFECTIVE_CONFIG_DIR" ]]; then
    echo "ERROR: Effective configuration directory does not exist or is not a directory: $EFFECTIVE_CONFIG_DIR" >&2
    echo "       Please create it or use the --config-dir option to specify the correct path." >&2
    exit 1
fi
echo "INFO: Using effective user configuration directory: $EFFECTIVE_CONFIG_DIR"


# --- Determine Full Path to the Source Environment File (Theme 4 - UE3) ---
ENV_PATH=""
if [[ "$ENV_ARG_CAPTURED" = /* ]]; then
  # Absolute path provided
  ENV_PATH="$ENV_ARG_CAPTURED"
elif [[ "$ENV_ARG_CAPTURED" == */* ]]; then
  # Relative path (contains a slash) - resolve it relative to CWD
  if ! env_path_realpath_tmp="$(realpath "$ENV_ARG_CAPTURED" 2>/dev/null)"; then
    echo "ERROR: Invalid relative path for environment file: $ENV_ARG_CAPTURED" >&2
    exit 1
  fi
  ENV_PATH="$env_path_realpath_tmp"
else
  # Just a filename — assume it lives in <EFFECTIVE_CONFIG_DIR>/<ENV_FILES_SUBDIR>/
  PROPOSED_PATH="$EFFECTIVE_CONFIG_DIR/$ENV_FILES_SUBDIR/$ENV_ARG_CAPTURED"
  if ! env_path_realpath_tmp="$(realpath "$PROPOSED_PATH" 2>/dev/null)"; then
     echo "ERROR: Could not resolve path for environment file '$ENV_ARG_CAPTURED' expected at '$PROPOSED_PATH'" >&2
     exit 1
  fi
  ENV_PATH="$env_path_realpath_tmp"
fi

# --- Define Target Symlink Location (Theme 4 - UE3) ---
# This is the 'backup.env' in the root of the *user's effective configuration directory*
TARGET_LINK="$EFFECTIVE_CONFIG_DIR/backup.env"

# --- Validate Source Environment File ---
if [[ ! -f "$ENV_PATH" ]]; then
  echo "ERROR: Source environment file not found or is not a regular file: $ENV_PATH" >&2
  exit 1
fi

# --- Create/Update Symlink ---
echo "Attempting to link: $TARGET_LINK -> $ENV_PATH"
if ln -sf "$ENV_PATH" "$TARGET_LINK"; then
  echo "Successfully linked '$TARGET_LINK' to '$ENV_PATH'."
else
  # This error case was not explicitly in original, but good practice from target
  echo "ERROR: Failed to create symlink. Check permissions or paths." >&2
  exit 1
fi

# Repository convenience symlink logic will be added in Theme 5 (Step UE4)
