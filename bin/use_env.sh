#!/bin/bash

set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Default User Configuration & Paths ---
USER_CONFIG_DEFAULT="$HOME/.config/$PROJECT_NAME"
ENV_FILES_SUBDIR="env"

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

# --- Argument Parsing (from Theme 1) ---
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

# --- Determine Effective Configuration Directory (Theme 2 Core) ---
if [[ -n "$CONFIG_DIR_ARG" ]]; then
  EFFECTIVE_CONFIG_DIR="$CONFIG_DIR_ARG"
else
  EFFECTIVE_CONFIG_DIR="$USER_CONFIG_DEFAULT"
fi

# --- Validate and Resolve EFFECTIVE_CONFIG_DIR (Theme 3 Core) ---
# Store the original path for error messages before realpath potentially changes it or fails
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
# At this point, EFFECTIVE_CONFIG_DIR is a validated, existing, absolute directory path.
echo "INFO: Using effective user configuration directory: $EFFECTIVE_CONFIG_DIR"


# The following logic for ENV_PATH and TARGET_LINK remains unchanged from Theme 1 & 2.
# It does NOT yet use EFFECTIVE_CONFIG_DIR. This is for Theme 4 (Step UE3).

# Determine full path
ENV_PATH=""
if [[ "$ENV_ARG_CAPTURED" = /* ]]; then
  ENV_PATH="$ENV_ARG_CAPTURED"
elif [[ "$ENV_ARG_CAPTURED" == */* ]]; then
  ENV_PATH="$(realpath "$ENV_ARG_CAPTURED")" # This realpath is for the ENV_ARG itself if relative
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ENV_PATH="$(realpath "$SCRIPT_DIR/../config/env/$ENV_ARG_CAPTURED")"
fi

# Target symlink location
TARGET_LINK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/backup.env"

if [[ ! -f "$ENV_PATH" ]]; then
  echo "ERROR: No such env file: $ENV_PATH" >&2
  exit 1
fi

ln -sf "$ENV_PATH" "$TARGET_LINK"
echo "Linked $TARGET_LINK -> $ENV_PATH"
