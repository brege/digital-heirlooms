#!/bin/bash
set -euo pipefail

# --- Config Directory Resolution ---
# Default to script-relative config
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # Was BACKUPKIT_HOME
CONFIG_ROOT_DEFAULT="$REPO_ROOT/config"
CONFIG_ROOT="$CONFIG_ROOT_DEFAULT"

# Check for --config override and --help
# Note: Original script's argument parsing allows --config to be anywhere.
# This simple loop processes it if found. More robust parsing is a refactor goal.
for arg in "$@"; do
  case $arg in
    --config=*)
      CONFIG_ROOT="$(realpath "${arg#*=}")"
      # Original script shifted here. For sanitization, we'll note that this
      # simple loop doesn't remove it from $@ for later POSITIONAL processing.
      # A full refactor would handle this with a better loop.
      ;;
    --help|-h)
      echo "Usage: $0 [--config=/path/to/config] [enable|disable] <machine>"
      echo ""
      echo "Manages symlinks for machine configs."
      echo "Priority for config location:"
      echo "  1. --config flag"
      echo "  2. CONFIG_DIR set in config/backup.env (if backup.env is sourced and defines it)"
      echo "  3. Default to REPO_ROOT/config" # Was BACKUPKIT_HOME
      exit 0
      ;;
  esac
done

# Attempt to source backup.env and use CONFIG_DIR from there
# Note: backup.env is typically in CONFIG_ROOT_DEFAULT, not necessarily the overridden CONFIG_ROOT
ENV_FILE_TO_SOURCE="$CONFIG_ROOT_DEFAULT/backup.env"
if [[ -f "$ENV_FILE_TO_SOURCE" ]]; then
  # shellcheck disable=SC1090
  # Shortened: current_config_dir_val_before_source
  prev_cfg_dir_val="${CONFIG_DIR:-}" # Save current CONFIG_DIR if set by env
  source "$ENV_FILE_TO_SOURCE"
  # If --config was given, it takes precedence. Otherwise, let backup.env's CONFIG_DIR take effect.
  # This logic assumes CONFIG_DIR in backup.env is the *main* config dir.
  if [[ "$CONFIG_ROOT" == "$CONFIG_ROOT_DEFAULT" ]]; then # Only override if --config was not used
    CONFIG_ROOT="${CONFIG_DIR:-$CONFIG_ROOT}"
  else # If --config was used, restore CONFIG_DIR from backup.env if it was set
    CONFIG_DIR="${prev_cfg_dir_val}"
  fi
fi

# These paths should be relative to the final CONFIG_ROOT
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
AVAILABLE_DIR="$CONFIG_ROOT/machines-available"

# --- Globals & Defaults ---

# ACTION should be the first argument after any --config flag has been *conceptually* processed.
# This script's original arg parsing is simple; robust parsing is for refactoring.
ACTION="${1:-}"
if [[ -z "$ACTION" || ( "$ACTION" != "enable" && "$ACTION" != "disable" ) ]]; then
  # If no action or invalid action, and it's not a --help case (handled above)
  if [[ $# -lt 2 && "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then
    echo "ERROR: Invalid action or missing arguments. Use 'enable' or 'disable' followed by machine name(s)." >&2
    echo "Run '$0 --help' for more information." >&2 # Also to stderr
    exit 1
  fi
  if [[ "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then
    echo "ERROR: Invalid action '$ACTION'. Must be 'enable' or 'disable'." >&2
    echo "Run '$0 --help' for more information." >&2 # Also to stderr
    exit 1
  fi
fi

# Shift action so $@ contains only machine names.
# This shift happens *after* the --config loop, so if --config was not the first arg,
# this might not behave as intended if --config is between action and machines.
# This is a limitation of the original script's parsing logic.
if [[ $# -gt 0 ]]; then # Ensure there's something to shift
    shift || true 
else # Should have been caught by previous checks if ACTION was expected
    echo "ERROR: No arguments found to process for action and machine names." >&2
    exit 1
fi


if [[ $# -eq 0 ]]; then
  echo "ERROR: No machine names provided for action '$ACTION'." >&2
  echo "Run '$0 --help' for more information." >&2 # Also to stderr
  exit 1
fi

# --- Enable/Disable Machines ---

# This block is now correctly processed after action and machine names are confirmed.
for machine in "$@"; do
  machine_config_path="$AVAILABLE_DIR/$machine"
  if [[ ! -f "$machine_config_path" ]]; then
    echo "WARN: Configuration file for '$machine' not found in $AVAILABLE_DIR. Skipping." >&2
    continue
  fi

  target_link="$MACHINES_ENABLED_DIR/$machine"
  if [[ "$ACTION" == "enable" ]]; then
    mkdir -p "$MACHINES_ENABLED_DIR"
    ln -sf "$machine_config_path" "$target_link"
    echo "Machine State: Enabled machine configuration for '$machine'."
  else # Action is "disable"
    if [[ -L "$target_link" ]]; then # Check if the symlink exists before trying to remove
      rm -f "$target_link"
      echo "Machine State: Disabled machine configuration for '$machine'."
    elif [[ -e "$target_link" ]]; then # It exists but is not a symlink
      echo "WARN: '$target_link' exists but is not a symlink. Manual removal may be required." >&2
    else
      echo "Machine State: Configuration for '$machine' was not enabled. No action taken."
    fi
  fi
done
