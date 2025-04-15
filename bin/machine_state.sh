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
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--config=/path/to/config] [enable|disable] <machine>"
      echo
      echo "Manages symlinks for machine configs."
      echo "Priority for config location:"
      echo "  1. --config flag"
      echo "  2. CONFIG_DIR set in config/backup.env"
      echo "  3. Default to '../config' relative to script"
      exit 0
      ;;
  esac
done

# Attempt to source backup.env and use CONFIG_DIR from there
ENV_FILE="$CONFIG_ROOT_DEFAULT/backup.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  CONFIG_ROOT="${CONFIG_DIR:-$CONFIG_ROOT}"  # Allow env override if not set by --config
fi

CONFIG_DIR="$CONFIG_ROOT/machines-enabled"
AVAILABLE_DIR="$CONFIG_ROOT/machines-available"

# ----------------------------------------
# 🌐 Globals & Defaults
# ----------------------------------------

ACTION="${1:-enable}"
shift || true

# ----------------------------------------
# 📦 Enable/Disable Machines
# ----------------------------------------

if [[ "$ACTION" == "enable" || "$ACTION" == "disable" ]]; then
  for machine in "$@"; do
    machine_config="$AVAILABLE_DIR/$machine"
    if [[ ! -f "$machine_config" ]]; then
      echo "⚠️  No config found for $machine in $AVAILABLE_DIR. Skipping."
      continue
    fi

    target_link="$CONFIG_DIR/$machine"
    if [[ "$ACTION" == "enable" ]]; then
      mkdir -p "$CONFIG_DIR"
      ln -sf "$machine_config" "$target_link"
      echo "🔹 Enabled machine: $machine"
    else
      rm -f "$target_link"
      echo "🔹 Disabled machine: $machine"
    fi
  done
else
  echo "❗ Error: Invalid action. Use 'enable' or 'disable'."
  exit 1
fi

