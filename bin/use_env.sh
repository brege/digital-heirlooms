#!/bin/bash

set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Default User Configuration (for print_usage context in Theme 1) ---
# This will be used more actively in Theme 2.
USER_CONFIG_DEFAULT="$HOME/.config/$PROJECT_NAME"

# --- Argument Storage ---
ENV_ARG_CAPTURED=""
CONFIG_DIR_ARG="" # To store value from --config-dir

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

# Validate that the environment argument was provided
if [[ -z "$ENV_ARG_CAPTURED" ]]; then
  echo "ERROR: No environment file specified." >&2
  print_usage
  exit 1
fi

# Determine full path
# Note: This path resolution logic will be updated in Theme 3 to use CONFIG_DIR_ARG
# For Theme 1, it uses ENV_ARG_CAPTURED instead of the original ENV_ARG.
ENV_PATH=""
if [[ "$ENV_ARG_CAPTURED" = /* ]]; then
  # Absolute path
  ENV_PATH="$ENV_ARG_CAPTURED"
elif [[ "$ENV_ARG_CAPTURED" == */* ]]; then
  # Relative path already includes directories
  ENV_PATH="$(realpath "$ENV_ARG_CAPTURED")"
else
  # Just a filename — assume it lives in ../config/env relative to script dir (old logic)
  # This will be updated in Theme 3.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ENV_PATH="$(realpath "$SCRIPT_DIR/../config/env/$ENV_ARG_CAPTURED")"
fi

# Target symlink location
# Note: This path will be updated in Theme 3 to use CONFIG_DIR_ARG
TARGET_LINK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/backup.env"

if [[ ! -f "$ENV_PATH" ]]; then
  echo "ERROR: No such env file: $ENV_PATH" >&2
  exit 1
fi

ln -sf "$ENV_PATH" "$TARGET_LINK"
echo "Linked $TARGET_LINK -> $ENV_PATH"
