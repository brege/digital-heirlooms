#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Script Path & Default Config Path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_ROOT_DEFAULT="$REPO_ROOT/config"

# --- Argument Storage ---
ACTION="" # Was ACTION_CAPTURED, reverting to original name's intent
MACHINE_NAMES=() # Was MACHINE_NAMES_CAPTURED
config_arg=""   # Was CONFIG_DIR_ARG, now shorter and lowercase

print_usage() {
  echo "Usage: $0 [OPTIONS] <action> <machine_name> [machine_name...]"
  echo ""
  echo "Manages symlinks for machine configurations for $PROJECT_NAME."
  echo ""
  echo "Actions:"
  echo "  enable                 Enable the specified machine(s) for backup."
  echo "  disable                Disable the specified machine(s) for backup."
  echo ""
  echo "Options:"
  echo "  --config <path>        Specify the root directory for $PROJECT_NAME configurations."
  echo "                         Overrides default behavior of using '$CONFIG_ROOT_DEFAULT'"
  echo "                         or the CONFIG_DIR from '$CONFIG_ROOT_DEFAULT/backup.env'."
  echo "  --help, -h             Show this help message."
}

# --- Argument Parsing for Options ---
while [[ $# -gt 0 ]]; do
  current_arg="$1" # Using a more common name for the loop variable
  case "$current_arg" in
    --config=*)
      config_arg="${current_arg#*=}"
      shift
      ;;
    --config)
      if [[ -n "${2:-}" && "${2}" != --* ]]; then
        config_arg="$2"
        shift 2
      else
        echo "ERROR: --config requires a value." >&2
        print_usage
        exit 1
      fi
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $current_arg" >&2
      print_usage
      exit 1
      ;;
    *)
      break # End of options
      ;;
  esac
done

# --- Config Directory Resolution (Preserving Original Logic with New Arg Parser) ---
CONFIG_ROOT="$CONFIG_ROOT_DEFAULT" # Default to script-relative config

if [[ -n "$config_arg" ]]; then
  # If --config was used, it takes highest precedence.
  if ! config_root_realpath="$(realpath "$config_arg" 2>/dev/null)"; then # Shorter temp var
      echo "ERROR: Invalid path specified with --config: $config_arg" >&2
      exit 1
  fi
  CONFIG_ROOT="$config_root_realpath"
else
  # If --config was NOT used, attempt to source backup.env from default location
  # This preserves the original script's behavior.
  # Using original variable name "ENV_FILE_TO_SOURCE"
  ENV_FILE_TO_SOURCE="$CONFIG_ROOT_DEFAULT/backup.env"
  if [[ -f "$ENV_FILE_TO_SOURCE" ]]; then
    # shellcheck disable=SC1090
    # Using original variable name "prev_cfg_dir_val" and its exact original definition
    prev_cfg_dir_val="${CONFIG_DIR:-}" 
    
    # Sourcing carefully to get CONFIG_DIR value IF SET BY THE SOURCED FILE
    # Using a more concise variable "sourced_cfg_dir"
    sourced_cfg_dir=$(CONFIG_DIR="" source "$ENV_FILE_TO_SOURCE" >/dev/null 2>&1 && echo "$CONFIG_DIR")

    if [[ -n "$sourced_cfg_dir" ]]; then
        # If backup.env defined CONFIG_DIR, use it.
        if ! sourced_cfg_dir_realpath="$(realpath "$sourced_cfg_dir" 2>/dev/null)"; then # Shorter temp var
            echo "ERROR: Invalid CONFIG_DIR specified in $ENV_FILE_TO_SOURCE: $sourced_cfg_dir" >&2
            exit 1
        fi
        CONFIG_ROOT="$sourced_cfg_dir_realpath"
    fi
    # Restoring CONFIG_DIR variable to its state before sourcing, as in the original script
    CONFIG_DIR="${prev_cfg_dir_val}" 
  fi
fi

# --- Positional Argument Processing (Action and Machine Names) ---
if [[ $# -gt 0 ]]; then
  ACTION="$1" # Use original variable name
  shift
  MACHINE_NAMES=("$@") # Use concise name
else
  if [[ -z "$ACTION" ]]; then # ACTION would be empty if only options were passed
      echo "ERROR: No action specified." >&2
      print_usage
      exit 1
  fi
fi

# --- Validate Action and Machine Names ---
if [[ "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then
  echo "ERROR: Invalid action '$ACTION'. Must be 'enable' or 'disable'." >&2
  print_usage
  exit 1
fi

if [[ ${#MACHINE_NAMES[@]} -eq 0 ]]; then
  echo "ERROR: No machine names provided for action '$ACTION'." >&2
  print_usage
  exit 1
fi

# --- Define Paths Relative to Final CONFIG_ROOT ---
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
AVAILABLE_DIR="$CONFIG_ROOT/machines-available" # Original name from input script

# --- Enable/Disable Machines ---
echo "Using configuration root: $CONFIG_ROOT"

for machine in "${MACHINE_NAMES[@]}"; do
  machine_config_path="$AVAILABLE_DIR/$machine"
  if [[ ! -f "$machine_config_path" ]]; then
    echo "WARN: Configuration file for '$machine' not found in $AVAILABLE_DIR. Skipping." >&2
    continue
  fi

  target_link="$MACHINES_ENABLED_DIR/$machine"
  if [[ "$ACTION" == "enable" ]]; then
    if [[ ! -d "$MACHINES_ENABLED_DIR" ]]; then
        mkdir -p "$MACHINES_ENABLED_DIR"
    fi
    ln -sf "$machine_config_path" "$target_link"
    echo "Machine State: Enabled machine configuration for '$machine'."
  else # Action is "disable"
    if [[ -L "$target_link" ]]; then
      rm -f "$target_link"
      echo "Machine State: Disabled machine configuration for '$machine'."
    elif [[ -e "$target_link" ]]; then
      echo "WARN: '$target_link' exists but is not a symlink. Manual removal may be required." >&2
    else
      echo "Machine State: Configuration for '$machine' was not enabled. No action taken for 'disable'."
    fi
  fi
done
