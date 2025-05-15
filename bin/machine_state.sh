#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Script Path & Default Config Path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_ROOT_DEFAULT="$REPO_ROOT/config" # Repo's default config/

# --- Standard User Config Paths ---
USER_HOME_CFG_ROOT="$HOME/.config/$PROJECT_NAME"
USER_HOME_ENV_FILE="$USER_HOME_CFG_ROOT/backup.env"

# --- Argument Storage ---
ACTION=""
MACHINE_NAMES=()
config_arg=""   # Stores value from --config

# This will hold the final, validated configuration root path
CONFIG_ROOT=""

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
  echo "                         Overrides default discovery logic."
  echo "  --help, -h             Show this help message."
  echo ""
  echo "Configuration Discovery Order (if --config is not used):"
  echo "  1. Path in CONFIG_DIR variable from '$USER_HOME_ENV_FILE'."
  echo "  2. The directory '$USER_HOME_CFG_ROOT' itself, if 'backup.env' exists there."
  echo "  3. Path in CONFIG_DIR variable from '$CONFIG_ROOT_DEFAULT/backup.env'."
  echo "  4. The directory '$CONFIG_ROOT_DEFAULT' itself, if 'backup.env' exists there."
}

# --- Argument Parsing for Options ---
while [[ $# -gt 0 ]]; do
  current_arg="$1"
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

# --- Positional Argument Processing (Action and Machine Names) ---
if [[ $# -gt 0 ]]; then
  ACTION="$1"
  shift
  MACHINE_NAMES=("$@")
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

# --- Resolve Final Configuration Root Directory (Theme 3 - MS2, revised for conciseness) ---
# This logic mirrors the structure of machine_state.sane.new.sh's config resolution.

# 1. Via --config argument
if [[ -n "$config_arg" ]]; then
  echo "INFO: --config flag provided, attempting to use: $config_arg"
  cfg_realpath_tmp="" # temp variable for realpath result
  if ! cfg_realpath_tmp="$(realpath "$config_arg" 2>/dev/null)"; then
    echo "ERROR: Invalid path specified with --config: '$config_arg' (realpath failed)." >&2
    exit 1
  fi
  if [[ ! -d "$cfg_realpath_tmp" ]]; then
    echo "ERROR: Path specified with --config is not a directory: '$cfg_realpath_tmp'." >&2
    exit 1
  fi
  if [[ ! -f "$cfg_realpath_tmp/backup.env" ]]; then
    # Target script issues a warning but still uses the path if it's a dir.
    echo "WARN: Directory specified with --config does not contain a 'backup.env' file: '$cfg_realpath_tmp'." >&2
    echo "      Proceeding, but essential configuration variables might be missing." >&2
  fi
  CONFIG_ROOT="$cfg_realpath_tmp"
fi

# 2. Via CONFIG_DIR in user's standard home config ($USER_HOME_ENV_FILE)
if [[ -z "$CONFIG_ROOT" && -f "$USER_HOME_ENV_FILE" ]]; then
  sourced_cfg_dir_val=$(CONFIG_DIR="" source "$USER_HOME_ENV_FILE" >/dev/null 2>&1 && echo "$CONFIG_DIR")
  if [[ -n "$sourced_cfg_dir_val" ]]; then
    echo "INFO: Found CONFIG_DIR in $USER_HOME_ENV_FILE: '$sourced_cfg_dir_val'"
    cfg_realpath_tmp=""
    if ! cfg_realpath_tmp="$(realpath "$sourced_cfg_dir_val" 2>/dev/null)"; then
      echo "WARN: Invalid CONFIG_DIR ('$sourced_cfg_dir_val') from $USER_HOME_ENV_FILE. Realpath failed. Ignoring." >&2
    elif [[ ! -d "$cfg_realpath_tmp" ]]; then
      echo "WARN: CONFIG_DIR ('$cfg_realpath_tmp') from $USER_HOME_ENV_FILE is not a directory. Ignoring." >&2
    elif [[ ! -f "$cfg_realpath_tmp/backup.env" ]]; then
      echo "WARN: CONFIG_DIR ('$cfg_realpath_tmp') from $USER_HOME_ENV_FILE does not contain 'backup.env'. Ignoring." >&2
    else
      CONFIG_ROOT="$cfg_realpath_tmp"
    fi
  fi
fi

# 3. Via user's standard home config directory itself ($USER_HOME_CFG_ROOT)
if [[ -z "$CONFIG_ROOT" && -d "$USER_HOME_CFG_ROOT" && -f "$USER_HOME_ENV_FILE" ]]; then
  # This implies USER_HOME_CFG_ROOT is a potentially valid config root
  # because its backup.env exists (even if it didn't define a CONFIG_DIR to redirect).
  cfg_realpath_tmp=""
  if ! cfg_realpath_tmp="$(realpath "$USER_HOME_CFG_ROOT" 2>/dev/null)"; then
      echo "WARN: Could not resolve realpath for '$USER_HOME_CFG_ROOT'. This is unexpected. Ignoring." >&2
  else
      CONFIG_ROOT="$cfg_realpath_tmp"
      echo "INFO: Using user's standard config directory '$CONFIG_ROOT' (backup.env present)."
  fi
fi

# Define REPO_DEFAULT_ENV_FILE for clarity in the next steps
REPO_DEFAULT_ENV_FILE="$CONFIG_ROOT_DEFAULT/backup.env"

# 4. Via CONFIG_DIR in repository's default config ($REPO_DEFAULT_ENV_FILE)
if [[ -z "$CONFIG_ROOT" && -f "$REPO_DEFAULT_ENV_FILE" ]]; then
  sourced_cfg_dir_val=$(CONFIG_DIR="" source "$REPO_DEFAULT_ENV_FILE" >/dev/null 2>&1 && echo "$CONFIG_DIR")
  if [[ -n "$sourced_cfg_dir_val" ]]; then
    echo "INFO: Found CONFIG_DIR in $REPO_DEFAULT_ENV_FILE: '$sourced_cfg_dir_val'"
    cfg_realpath_tmp=""
    if ! cfg_realpath_tmp="$(realpath "$sourced_cfg_dir_val" 2>/dev/null)"; then
      echo "WARN: Invalid CONFIG_DIR ('$sourced_cfg_dir_val') from $REPO_DEFAULT_ENV_FILE. Realpath failed. Ignoring." >&2
    elif [[ ! -d "$cfg_realpath_tmp" ]]; then
      echo "WARN: CONFIG_DIR ('$cfg_realpath_tmp') from $REPO_DEFAULT_ENV_FILE is not a directory. Ignoring." >&2
    elif [[ ! -f "$cfg_realpath_tmp/backup.env" ]]; then
      echo "WARN: CONFIG_DIR ('$cfg_realpath_tmp') from $REPO_DEFAULT_ENV_FILE does not contain 'backup.env'. Ignoring." >&2
    else
      CONFIG_ROOT="$cfg_realpath_tmp"
    fi
  fi
fi

# 5. Fallback to repository's default config directory itself ($CONFIG_ROOT_DEFAULT)
if [[ -z "$CONFIG_ROOT" && -d "$CONFIG_ROOT_DEFAULT" && -f "$REPO_DEFAULT_ENV_FILE" ]]; then
  # This implies CONFIG_ROOT_DEFAULT is a potentially valid config root.
  cfg_realpath_tmp=""
  if ! cfg_realpath_tmp="$(realpath "$CONFIG_ROOT_DEFAULT" 2>/dev/null)"; then
    echo "WARN: Could not resolve realpath for '$CONFIG_ROOT_DEFAULT'. This is unexpected. Ignoring." >&2
  else
    CONFIG_ROOT="$cfg_realpath_tmp"
    echo "INFO: Using repository default configuration directory '$CONFIG_ROOT' (backup.env present)."
  fi
fi

# Final check and assignment
if [[ -z "$CONFIG_ROOT" ]]; then
  echo "ERROR: Could not determine a valid $PROJECT_NAME configuration root directory." >&2
  echo "       Please use the --config option or ensure a valid setup exists in one of the default locations:" >&2
  echo "       1. $USER_HOME_CFG_ROOT (and its backup.env)" >&2
  echo "       2. $CONFIG_ROOT_DEFAULT (and its backup.env)" >&2
  exit 1
fi

echo "INFO: Effective configuration root: $CONFIG_ROOT"


# --- Define Paths Relative to Final CONFIG_ROOT ---
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
MACHINES_AVAIL_DIR="$CONFIG_ROOT/machines-available" # Renamed for consistency

# --- Enable/Disable Machines ---
for machine in "${MACHINE_NAMES[@]}"; do
  machine_config_path="$MACHINES_AVAIL_DIR/$machine"
  if [[ ! -f "$machine_config_path" ]]; then
    echo "WARN: Configuration file for '$machine' not found in $MACHINES_AVAIL_DIR. Skipping." >&2
    continue
  fi

  target_link="$MACHINES_ENABLED_DIR/$machine"
  if [[ "$ACTION" == "enable" ]]; then
    if [[ ! -d "$MACHINES_ENABLED_DIR" ]]; then
        mkdir -p "$MACHINES_ENABLED_DIR"
    fi
    source_cfg_file_rpath="" # temp var for realpath
    if ! source_cfg_file_rpath="$(realpath "$machine_config_path" 2>/dev/null)"; then
        echo "WARN: Could not resolve real path for source machine config: '$machine_config_path'. Skipping enable for '$machine'." >&2
        continue
    fi
    ln -sf "$source_cfg_file_rpath" "$target_link"
    echo "Machine State: Enabled machine configuration for '$machine' ($target_link -> $source_cfg_file_rpath)."
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
