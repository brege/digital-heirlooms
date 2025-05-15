#!/bin/bash

set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Default User Configuration & Paths ---
USER_CONFIG_DEFAULT="$HOME/.config/$PROJECT_NAME"
ENV_FILES_SUBDIR="env" # Standard subdirectory for environment files

# This variable will hold the determined configuration directory
EFFECTIVE_CONFIG_DIR="" # Will be set after argument parsing

# --- Argument Storage ---
ENV_ARG_CAPTURED=""
CONFIG_DIR_ARG="" # Stores value from --config-dir

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

# Validate that the environment argument was provided
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
# Note: Validation of this path (realpath, dir check) occurs in Theme 3 (Step UE2).
# Usage of this path for ENV_PATH and TARGET_LINK occurs in Theme 4 (Step UE3).

# The following logic for ENV_PATH and TARGET_LINK remains unchanged from Theme 1.
# It does NOT yet use EFFECTIVE_CONFIG_DIR. This is intentional for this theme.

# Determine full path
ENV_PATH=""
if [[ "$ENV_ARG_CAPTURED" = /* ]]; then
  # Absolute path
  ENV_PATH="$ENV_ARG_CAPTURED"
elif [[ "$ENV_ARG_CAPTURED" == */* ]]; then
  # Relative path already includes directories
  ENV_PATH="$(realpath "$ENV_ARG_CAPTURED")"
else
  # Just a filename — assume it lives in ../config/env relative to script dir (old logic)
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
# An echo statement confirming EFFECTIVE_CONFIG_DIR could be added here or after validation in Theme 3.
# For now, keeping changes minimal to just setting the variable.
