#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Script Path & Default Config Path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_ROOT_DEFAULT="$REPO_ROOT/config" 

# --- Standard User Config Paths ---
USER_HOME_CFG_ROOT="$HOME/.config/$PROJECT_NAME"
USER_HOME_ENV_FILE="$USER_HOME_CFG_ROOT/backup.env"

# --- Argument Storage ---
ACTION=""
MACHINE_NAMES=()
config_arg=""   

CONFIG_ROOT=""

# --- Helper Function: List Machines from a Directory ---
# $1: Directory to list contents from
# $2: Descriptive label for the type of machines being listed
_list_machines_from_dir() {
  local dir_to_list="$1"
  local description="$2"
  local found_any=false

  if [[ ! -d "$dir_to_list" ]]; then
    echo "INFO: Directory for $description ('$dir_to_list') does not exist."
    return
  fi
  
  echo "$description from '$dir_to_list':"
  local item
  for item in "$dir_to_list"/* "$dir_to_list"/.*; do 
    if [[ -e "$item" || -L "$item" ]] && [[ "$(basename "$item")" != "." && "$(basename "$item")" != ".." ]]; then 
      found_any=true
      local display_item
      display_item="$(basename "$item")" 

      if [[ -L "$item" ]]; then 
        local target
        target="$(readlink "$item")" || target="<error reading link>"
        display_item+=" -> $target" 
         if [[ ! -e "$item" ]]; then 
            display_item+=" (broken)"
         fi
      fi
      echo "  $display_item"
    fi
  done

  if [[ "$found_any" == false ]]; then
    echo "  (No machines $description)"
  fi
}

# --- Action Helper: List Available Machines ---
list_available_machines() {
  _list_machines_from_dir "$MACHINES_AVAIL_DIR" "Available machines"
}

# --- Action Helper: List Enabled Machines ---
list_enabled_machines() {
  _list_machines_from_dir "$MACHINES_ENABLED_DIR" "Enabled machines (symlinks)"
}

# --- Action Helper: Show Status of All Available Machines ---
show_machine_status() {
  echo "Machine Status (Config Root: $CONFIG_ROOT):"
  if [[ ! -d "$MACHINES_AVAIL_DIR" ]]; then
    echo "  INFO: Directory for available machines ('$MACHINES_AVAIL_DIR') does not exist."
    return
  fi

  local found_any_available=false
  local machine_file
  for machine_file in "$MACHINES_AVAIL_DIR"/* "$MACHINES_AVAIL_DIR"/.*; do
    if [[ ! -e "$machine_file" && ! -L "$machine_file" ]] || [[ "$(basename "$machine_file")" == "." || "$(basename "$machine_file")" == ".." ]]; then
        continue 
    fi
    found_any_available=true
    local machine_name
    machine_name="$(basename "$machine_file")"
    local status="Not Enabled"
    local target_link="$MACHINES_ENABLED_DIR/$machine_name" 

    if [[ -L "$target_link" ]]; then 
      local real_source_path 
      real_source_path="$(readlink "$target_link")" || real_source_path="<error reading link>"
      
      local expected_source_path 
      expected_source_path_tmp=""
      if ! expected_source_path_tmp="$(realpath "$machine_file" 2>/dev/null)"; then
          expected_source_path="<error resolving path for $machine_file>"
      else
          expected_source_path="$expected_source_path_tmp"
      fi

      if [[ "$real_source_path" == "$expected_source_path" ]]; then
        status="Enabled"
      elif [[ -e "$target_link" ]]; then 
        status="Enabled (Warning: Symlink points to '$real_source_path', expected '$expected_source_path')"
      else 
        status="Enabled (Error: Symlink is BROKEN, points to '$real_source_path')"
      fi
    elif [[ -e "$target_link" ]]; then 
      status="Not Enabled (Conflict: Item '$target_link' exists but is not a symlink)"
    fi
    echo "  $machine_name: $status"
  done

  if [[ "$found_any_available" == false ]]; then
    echo "  (No machines found in $MACHINES_AVAIL_DIR to check status for)"
  fi
}

# --- print_usage function ---
print_usage() {
  echo "Usage: $0 [OPTIONS] <action> [machine_name...]"
  echo ""
  echo "Manages symlinks for machine configurations for $PROJECT_NAME."
  echo ""
  echo "Actions:"
  echo "  enable <machine...>    Enable the specified machine(s) for backup."
  echo "  disable <machine...>   Disable the specified machine(s) for backup."
  echo "  list-available         List all machines in the 'machines-available' directory."
  echo "  list-enabled           List all currently enabled machines (symlinks)."
  echo "  status | list          Show the enablement status of all available machines."
  echo ""
  echo "Options:"
  echo "  --config <path>        Specify the root directory for $PROJECT_NAME configurations."
  echo "                         Overrides default discovery logic."
  echo "  --help, -h             Show this help message."
  echo ""
  echo "Configuration Discovery Order (if --config is not used):"
  echo "  1. User specific: '$USER_HOME_CFG_ROOT' (via its backup.env or as the directory itself)."
  echo "  2. Repository default: '$CONFIG_ROOT_DEFAULT' (via its backup.env or as the directory itself)."
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
      break 
      ;;
  esac
done

# --- Positional Argument Processing (Action and Machine Names) ---
if [[ $# -gt 0 ]]; then
  ACTION="$1"
  shift
  MACHINE_NAMES=("$@") 
else
  if [[ -z "$ACTION" ]]; then 
      echo "ERROR: No action specified." >&2
      print_usage
      exit 1
  fi
fi

# --- Validate Action and Machine Name Arguments based on Action Type ---
case "$ACTION" in
  enable|disable)
    if [[ ${#MACHINE_NAMES[@]} -eq 0 ]]; then
      echo "ERROR: Action '$ACTION' requires at least one machine name." >&2
      print_usage
      exit 1
    fi
    ;;
  list-available|list-enabled|status|list)
    if [[ ${#MACHINE_NAMES[@]} -gt 0 ]]; then
      echo "WARN: Action '$ACTION' does not take machine name arguments. Ignoring extra arguments: ${MACHINE_NAMES[*]}" >&2
      MACHINE_NAMES=() 
    fi
    ;;
  *)
    echo "ERROR: Invalid action '$ACTION'." >&2
    print_usage
    exit 1
    ;;
esac

# --- Resolve Final Configuration Root Directory ---
CONFIG_CANDIDATE_REALPATH=""
_try_set_config_root() {
  local path_to_check="$1"
  local description="$2"
  local temp_realpath
  if ! temp_realpath="$(realpath "$path_to_check" 2>/dev/null)"; then
    echo "WARN: $description: Path '$path_to_check' is invalid (realpath failed). Ignoring." >&2
    return 1
  fi
  if [[ ! -d "$temp_realpath" ]]; then
    echo "WARN: $description: Path '$temp_realpath' is not a directory. Ignoring." >&2
    return 1
  fi
  if [[ ! -f "$temp_realpath/backup.env" ]]; then
    echo "WARN: $description: Directory '$temp_realpath' does not contain a 'backup.env' file. Ignoring." >&2
    return 1
  fi
  CONFIG_CANDIDATE_REALPATH="$temp_realpath"
  return 0
}

if [[ -n "$config_arg" ]]; then
  echo "INFO: --config flag provided, attempting to use: '$config_arg'"
  cfg_realpath_tmp="" 
  if ! cfg_realpath_tmp="$(realpath "$config_arg" 2>/dev/null)"; then
    echo "ERROR: Invalid path specified with --config: '$config_arg' (realpath failed)." >&2
    exit 1
  fi
  if [[ ! -d "$cfg_realpath_tmp" ]]; then
    echo "ERROR: Path specified with --config is not a directory: '$cfg_realpath_tmp'." >&2
    exit 1
  fi
  if [[ ! -f "$cfg_realpath_tmp/backup.env" ]]; then
    echo "WARN: Directory specified with --config ('$cfg_realpath_tmp') does not contain a 'backup.env' file." >&2
    echo "      Proceeding, but essential configuration variables might be missing." >&2
  fi
  CONFIG_ROOT="$cfg_realpath_tmp"
fi

if [[ -z "$CONFIG_ROOT" ]]; then
  if [[ -f "$USER_HOME_ENV_FILE" ]]; then 
    sourced_cfg_dir=$(CONFIG_DIR="" source "$USER_HOME_ENV_FILE" >/dev/null 2>&1 && echo "${CONFIG_DIR:-}") # CORRECTED
    if [[ -n "$sourced_cfg_dir" ]]; then 
      echo "INFO: Found CONFIG_DIR in '$USER_HOME_ENV_FILE': '$sourced_cfg_dir'"
      if _try_set_config_root "$sourced_cfg_dir" "CONFIG_DIR from '$USER_HOME_ENV_FILE'"; then
        CONFIG_ROOT="$CONFIG_CANDIDATE_REALPATH"
      fi
    fi
  fi
  if [[ -z "$CONFIG_ROOT" ]]; then 
    if _try_set_config_root "$USER_HOME_CFG_ROOT" "User standard directory '$USER_HOME_CFG_ROOT'"; then
      CONFIG_ROOT="$CONFIG_CANDIDATE_REALPATH"
      echo "INFO: Using user's standard config directory '$CONFIG_ROOT' (backup.env present)."
    fi
  fi
fi

if [[ -z "$CONFIG_ROOT" ]]; then
  REPO_DEFAULT_ENV_FILE="$CONFIG_ROOT_DEFAULT/backup.env"
  if [[ -f "$REPO_DEFAULT_ENV_FILE" ]]; then 
    sourced_cfg_dir=$(CONFIG_DIR="" source "$REPO_DEFAULT_ENV_FILE" >/dev/null 2>&1 && echo "${CONFIG_DIR:-}") # CORRECTED
    if [[ -n "$sourced_cfg_dir" ]]; then 
      echo "INFO: Found CONFIG_DIR in '$REPO_DEFAULT_ENV_FILE': '$sourced_cfg_dir'"
      if _try_set_config_root "$sourced_cfg_dir" "CONFIG_DIR from '$REPO_DEFAULT_ENV_FILE'"; then
        CONFIG_ROOT="$CONFIG_CANDIDATE_REALPATH"
      fi
    fi
  fi
  if [[ -z "$CONFIG_ROOT" ]]; then 
    if _try_set_config_root "$CONFIG_ROOT_DEFAULT" "Repository default directory '$CONFIG_ROOT_DEFAULT'"; then
      CONFIG_ROOT="$CONFIG_CANDIDATE_REALPATH"
      echo "INFO: Using repository default configuration directory '$CONFIG_ROOT' (backup.env present)."
    fi
  fi
fi

if [[ -z "$CONFIG_ROOT" ]]; then
  echo "ERROR: Could not determine a valid $PROJECT_NAME configuration root directory." >&2
  echo "       Please use the --config option or ensure a valid setup exists in:" >&2
  echo "       1. '$USER_HOME_CFG_ROOT' (containing a 'backup.env')" >&2
  echo "       2. '$CONFIG_ROOT_DEFAULT' (containing a 'backup.env')" >&2
  exit 1
fi

if [[ "$ACTION" != "list-available" && "$ACTION" != "list-enabled" && "$ACTION" != "status" && "$ACTION" != "list" ]]; then
    echo "INFO: Effective configuration root: $CONFIG_ROOT"
fi

# --- Define Paths Relative to Final CONFIG_ROOT ---
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
MACHINES_AVAIL_DIR="$CONFIG_ROOT/machines-available" 

# --- Perform Action ---
case "$ACTION" in
  enable)
    # --- Enable Machine(s) Logic ---
    echo "INFO: Action: Enable Machine(s)"
    for machine in "${MACHINE_NAMES[@]}"; do
      machine_config_path="$MACHINES_AVAIL_DIR/$machine"
      if [[ ! -f "$machine_config_path" ]]; then
        echo "WARN: Configuration file for '$machine' not found in $MACHINES_AVAIL_DIR. Skipping." >&2
        continue
      fi
      target_link="$MACHINES_ENABLED_DIR/$machine"
      if [[ ! -d "$MACHINES_ENABLED_DIR" ]]; then 
          mkdir -p "$MACHINES_ENABLED_DIR"
      fi
      source_cfg_file_rpath="" 
      if ! source_cfg_file_rpath="$(realpath "$machine_config_path" 2>/dev/null)"; then
          echo "WARN: Could not resolve real path for source machine config: '$machine_config_path'. Skipping enable for '$machine'." >&2
          continue
      fi
      ln -sf "$source_cfg_file_rpath" "$target_link"
      echo "Machine State: Enabled machine configuration for '$machine' ($target_link -> $source_cfg_file_rpath)."
    done
    ;;
  disable)
    # --- Disable Machine(s) Logic ---
    echo "INFO: Action: Disable Machine(s)"
    for machine in "${MACHINE_NAMES[@]}"; do
      target_link="$MACHINES_ENABLED_DIR/$machine"
      if [[ -L "$target_link" ]]; then 
        rm -f "$target_link"
        echo "Machine State: Disabled machine configuration for '$machine'."
      elif [[ -e "$target_link" ]]; then 
        echo "WARN: '$target_link' exists but is not a symlink. Manual removal may be required." >&2
      else 
        echo "Machine State: Configuration for '$machine' was not enabled. No action taken for 'disable'."
      fi
    done
    ;;
  list-available)
    # --- List Available Machines Action ---
    list_available_machines
    ;;
  list-enabled)
    # --- List Enabled Machines Action ---
    list_enabled_machines
    ;;
  status|list) 
    # --- Show Machine Status Action ---
    show_machine_status
    ;;
esac
