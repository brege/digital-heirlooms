#!/bin/bash
set -euo pipefail

# ----------------------------------------
# 🛠️ Config Directory Resolution
# ----------------------------------------

# Default to script-relative config
BACKUPKIT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_ROOT_DEFAULT="$BACKUPKIT_HOME/config"
CONFIG_ROOT="$CONFIG_ROOT_DEFAULT"

# Check for --config override
for arg in "$@"; do
  case $arg in
    --config=*)
      CONFIG_ROOT="$(realpath "${arg#*=}")"
      shift # Shift to remove --config from $@ so it doesn't interfere with ACTION and machine names
      ;;
    --help|-h)
      echo "Usage: $0 [--config=/path/to/config] [enable|disable] <machine>"
      echo
      echo "Manages symlinks for machine configs."
      echo "Priority for config location:"
      echo "  1. --config flag"
      echo "  2. CONFIG_DIR set in config/backup.env (if backup.env is sourced and defines it)"
      echo "  3. Default to BACKUPKIT_HOME/config"
      exit 0
      ;;
  esac
done

# Attempt to source backup.env and use CONFIG_DIR from there
# Note: backup.env is typically in CONFIG_ROOT_DEFAULT, not necessarily the overridden CONFIG_ROOT
ENV_FILE_TO_SOURCE="$CONFIG_ROOT_DEFAULT/backup.env" 
if [[ -f "$ENV_FILE_TO_SOURCE" ]]; then
  # shellcheck disable=SC1090
  current_config_dir_val_before_source="${CONFIG_DIR:-}" # Save current CONFIG_DIR if set by env
  source "$ENV_FILE_TO_SOURCE"
  # If --config was given, it takes precedence. Otherwise, let backup.env's CONFIG_DIR take effect.
  # This logic assumes CONFIG_DIR in backup.env is the *main* config dir, not specific to machines-available/enabled
  if [[ "$CONFIG_ROOT" == "$CONFIG_ROOT_DEFAULT" ]]; then # Only override if --config was not used
    CONFIG_ROOT="${CONFIG_DIR:-$CONFIG_ROOT}"
  else # If --config was used, restore CONFIG_DIR from backup.env if it was set, as it's a different variable
    CONFIG_DIR="${current_config_dir_val_before_source}"
  fi
fi

# These paths should be relative to the final CONFIG_ROOT
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
AVAILABLE_DIR="$CONFIG_ROOT/machines-available"

# ----------------------------------------
# 🌐 Globals & Defaults
# ----------------------------------------

# ACTION should be the first argument after any --config flag
ACTION="${1:-}" # Default action can be removed if explicit action is always required
if [[ -z "$ACTION" || ( "$ACTION" != "enable" && "$ACTION" != "disable" ) ]]; then
  # If no action or invalid action, and it's not a --help case (handled above)
  # Check if any machine names were provided. If not, it's likely a usage error.
  if [[ $# -lt 2 && "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then # Expecting at least action and machine
      echo "[ERROR] Invalid action or missing arguments. Use 'enable' or 'disable' followed by machine name(s)."
      echo "Run '$0 --help' for more information."
      exit 1
  fi
  # If arguments are present but action is not enable/disable, assume it might be machine names with implicit enable
  # Or handle as error. For now, require explicit action if first arg is not enable/disable.
  if [[ "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then
      echo "[ERROR] Invalid action '$ACTION'. Must be 'enable' or 'disable'."
      echo "Run '$0 --help' for more information."
      exit 1
  fi
fi

shift || true # Shift action so $@ contains only machine names

if [[ $# -eq 0 ]]; then
    echo "[ERROR] No machine names provided for action '$ACTION'."
    echo "Run '$0 --help' for more information."
    exit 1
fi
# ----------------------------------------
# 📦 Enable/Disable Machines
# ----------------------------------------

# This block is now correctly processed after action and machine names are confirmed.
for machine in "$@"; do
  machine_config_path="$AVAILABLE_DIR/$machine" # Corrected variable name
  if [[ ! -f "$machine_config_path" ]]; then
    echo "[WARN] Configuration file for '$machine' not found in $AVAILABLE_DIR. Skipping."
    continue
  fi

  target_link="$MACHINES_ENABLED_DIR/$machine"
  if [[ "$ACTION" == "enable" ]]; then
    mkdir -p "$MACHINES_ENABLED_DIR"
    ln -sf "$machine_config_path" "$target_link" # Use correct variable
    echo "Machine State: Enabled machine configuration for '$machine'."
  else # Action is "disable"
    if [[ -L "$target_link" ]]; then # Check if the symlink exists before trying to remove
        rm -f "$target_link"
        echo "Machine State: Disabled machine configuration for '$machine'."
    elif [[ -e "$target_link" ]]; then # It exists but is not a symlink (should not happen with this script)
        echo "[WARN] '$target_link' exists but is not a symlink. Manual removal may be required."
    else
        echo "Machine State: Configuration for '$machine' was not enabled. No action taken."
    fi
  fi
done
