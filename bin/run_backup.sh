#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Script Path & Default Config Path ---
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_ROOT_DEFAULT="$REPO_ROOT/config"

# --- Standard User Config Paths ---
USER_HOME_CFG_ROOT="$HOME/.config/$PROJECT_NAME"
USER_HOME_ENV_FILE="$USER_HOME_CFG_ROOT/backup.env"

# --- Argument Storage ---
CONFIG_ROOT_OVERRIDE="" 

# This will hold the final, validated configuration root path
CONFIG_ROOT=""

# --- print_usage function ---
print_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Runs the backup process for $PROJECT_NAME."
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

# --- Argument parsing ---
args_to_process=("$@")
idx=0
while [[ $idx -lt ${#args_to_process[@]} ]]; do
  arg_to_check="${args_to_process[$idx]}"
  case "$arg_to_check" in
    --help|-h)
      print_usage
      exit 0
      ;;
    --config)
      if [[ -n "${args_to_process[$((idx + 1))]:-}" && "${args_to_process[$((idx + 1))]}" != --* ]]; then
        CONFIG_ROOT_OVERRIDE="${args_to_process[$((idx + 1))]}"
        idx=$((idx + 1)) 
      else
        echo "WARN: --config flag found, but no value followed or value is another flag. Ignoring." >&2
      fi
      ;;
    --config=*)
      CONFIG_ROOT_OVERRIDE="${arg_to_check#*=}"
      ;;
    -*)
      echo "ERROR: Unknown option: $arg_to_check" >&2
      print_usage
      exit 1
      ;;
    *)
      :
      ;;
  esac
  ((idx++))
done

# --- Resolve Final Configuration Root Directory (Unified 3-Tier + Flag Logic) ---

# Helper function to check a potential config directory
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

# Tier 0: Explicit --config argument
if [[ -n "$CONFIG_ROOT_OVERRIDE" ]]; then
  echo "INFO: --config flag provided, attempting to use: '$CONFIG_ROOT_OVERRIDE'"
  cfg_realpath_tmp="" 
  if ! cfg_realpath_tmp="$(realpath "$CONFIG_ROOT_OVERRIDE" 2>/dev/null)"; then
    echo "ERROR: Invalid path specified with --config: '$CONFIG_ROOT_OVERRIDE' (realpath failed)." >&2
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

# Tier 1: User's Standard Configuration ($USER_HOME_CFG_ROOT)
if [[ -z "$CONFIG_ROOT" ]]; then
  if [[ -f "$USER_HOME_ENV_FILE" ]]; then 
    sourced_cfg_dir=$(CONFIG_DIR="" source "$USER_HOME_ENV_FILE" >/dev/null 2>&1 && echo "$CONFIG_DIR")
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

# Tier 2: Repository's Default Configuration ($CONFIG_ROOT_DEFAULT)
if [[ -z "$CONFIG_ROOT" ]]; then
  REPO_DEFAULT_ENV_FILE="$CONFIG_ROOT_DEFAULT/backup.env"
  if [[ -f "$REPO_DEFAULT_ENV_FILE" ]]; then 
    sourced_cfg_dir=$(CONFIG_DIR="" source "$REPO_DEFAULT_ENV_FILE" >/dev/null 2>&1 && echo "$CONFIG_DIR")
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

# Final check for CONFIG_ROOT
if [[ -z "$CONFIG_ROOT" ]]; then
  echo "ERROR: Could not determine a valid $PROJECT_NAME configuration root directory." >&2
  echo "       Please use the --config option or ensure a valid setup exists in:" >&2
  echo "       1. '$USER_HOME_CFG_ROOT' (containing a 'backup.env')" >&2
  echo "       2. '$CONFIG_ROOT_DEFAULT' (containing a 'backup.env')" >&2
  exit 1
fi

echo "INFO: Effective configuration root: $CONFIG_ROOT"

# --- Source Operational Environment File and Set Runtime Variables ---
ENV_FILE_TO_SOURCE="$CONFIG_ROOT/backup.env"
if [[ -f "$ENV_FILE_TO_SOURCE" ]]; then
  echo "INFO: Sourcing operational environment file: $ENV_FILE_TO_SOURCE"
  set -a  
  source "$ENV_FILE_TO_SOURCE"
  set +a
else
  echo "WARN: Operational environment file not found: $ENV_FILE_TO_SOURCE. Critical variables may be unset." >&2
  DRY_RUN="${DRY_RUN:-true}"
  LOCAL_TARGET_BASE="${LOCAL_TARGET_BASE:-}"
  REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
  LOCAL_ARCHIVE_BASE="${LOCAL_ARCHIVE_BASE:-}"
  REMOTE_ARCHIVE_BASE="${REMOTE_ARCHIVE_BASE:-}"
fi

# --- Define Core Operational Directories ---
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
EXCLUDES_DIR="$CONFIG_ROOT/excludes"
HOOKS_DIR="$CONFIG_ROOT/hooks-enabled"

echo "Using machine configs from: $MACHINES_ENABLED_DIR"
echo "Using excludes from: $EXCLUDES_DIR"
echo "Using hooks from: $HOOKS_DIR"

# --- Setup Global Rsync Exclude File ---
dflt_exclude_path="$EXCLUDES_DIR/default.exclude"
if [[ -f "$dflt_exclude_path" ]]; then
  echo "Applying global excludes from: $dflt_exclude_path"
  default_exclude="$dflt_exclude_path"
else
  default_exclude=""
  echo "No global exclude file found at $dflt_exclude_path (this is okay)."
fi

# --- Initialize Core Backup Variables and State ---
REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
DRY_RUN="${DRY_RUN:-false}"
# Not currently used, but present in original
direct_remote_rsync=false
staged_dirs=()

current_user=""
current_host=""
current_exclude=""
backup_paths=()
declare -A target_machine_roots

# --- Helper Function to Check for Localhost ---
is_local_host() {
  # Check if the given host is the local machine
  [[ "$1" == "localhost" || "$1" == "$(hostname)" || "$1" == "$(hostname -f)" ]]
}

# --- Backup Processing Function ---
flush_backup() {
  [[ ${#backup_paths[@]} -eq 0 ]] && return

  local staged_locally_this_flush=false

  # --- Iterate Over Source Paths for Current Machine ---
  for src_path in "${backup_paths[@]}"; do
    # Initialize with base options
    local rsync_cmd=(rsync -avzR --delete)

    # Add global exclude file
    if [[ -n "$default_exclude" && -f "$default_exclude" ]]; then
        rsync_cmd+=(--exclude-from="$default_exclude")
    fi
    # Add machine-specific exclude file
    if [[ -n "$current_exclude" && -f "$current_exclude" ]]; then
        rsync_cmd+=(--exclude-from="$current_exclude")
    fi

    # Scenario 1: Local staging then remote push
    if [[ -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"
      src_path_expanded=""
      # Assume SSH by default for this scenario if host isn't local
      use_ssh=true
      if is_local_host "$current_host"; then
        use_ssh=false
        src_path_expanded="$src_path"
      else
        src_path_expanded="$current_user@$current_host:$src_path"
      fi
      mkdir -p "$dest_dir"
      # Prevent recursion: Exclude the local target base
      if [[ "$LOCAL_TARGET_BASE" == /* ]]; then
          rsync_cmd+=(--exclude "$LOCAL_TARGET_BASE")
      fi
      if [[ "$DRY_RUN" == "true" ]]; then
         rsync_cmd+=(--dry-run)
      fi
      if [[ "$use_ssh" == true ]]; then
         rsync_cmd+=(-e ssh)
      fi
      rsync_cmd+=("$src_path_expanded" "$dest_dir")
      echo ""
      echo "Rsyncing to local staging ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $dest_dir"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true

    # Scenario 2: Direct remote push
    elif [[ -z "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      dest_dir="$REMOTE_TARGET_BASE/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"
      src_path_expanded="$current_user@$current_host:$src_path"
      if [[ "$DRY_RUN" == "true" ]]; then
        rsync_cmd+=(--dry-run)
      fi
      rsync_cmd+=(-e ssh "$src_path_expanded" "${dest_dir%/}/")
      echo ""
      echo "Rsyncing directly to remote ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> ${dest_dir%/}/"
      "${rsync_cmd[@]}"

    # Scenario 3: Local staging only (REMOTE_TARGET_BASE is empty)
    else
      if [[ -z "$LOCAL_TARGET_BASE" ]]; then
        echo "ERROR: flush_backup: LOCAL_TARGET_BASE is not set for local backup of $current_user@$current_host. Skipping path $src_path." >&2
        continue
      fi
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"
      src_path_expanded=""
      # Assume SSH if host isn't local
      use_ssh=true
      if is_local_host "$current_host"; then
        use_ssh=false
        src_path_expanded="$src_path"
      else
        src_path_expanded="$current_user@$current_host:$src_path"
      fi
      mkdir -p "$dest_dir"
      if [[ "$LOCAL_TARGET_BASE" == /* ]]; then
          rsync_cmd+=(--exclude "$LOCAL_TARGET_BASE")
      fi
      if [[ "$DRY_RUN" == "true" ]]; then
        rsync_cmd+=(--dry-run)
      fi
      if [[ "$use_ssh" == true ]]; then
        rsync_cmd+=(-e ssh)
      fi
      rsync_cmd+=("$src_path_expanded" "$dest_dir")
      echo ""
      echo "Rsyncing to local destination ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $dest_dir"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true
    fi
  done

  # --- Synchronize Staged Local Data to Remote Target (if applicable) ---
  if [[ "$staged_locally_this_flush" == true && -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
    local local_stage_path="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
    local remote_dest_path="$REMOTE_TARGET_BASE/$current_user@$current_host"
    echo ""
    echo "Syncing staged data for $current_user@$current_host to remote..."
    echo "Path: $local_stage_path/ -> $remote_dest_path/"
    local rsync_push_cmd=(rsync -az --delete --info=progress2)
    if [[ "$DRY_RUN" == "true" ]]; then
      rsync_push_cmd+=(--dry-run)
    fi
    rsync_push_cmd+=("$local_stage_path/" "$remote_dest_path/")
    "${rsync_push_cmd[@]}"
  fi

  backup_paths=()
  current_exclude=""
}

# --- Main Processing Loop for Machines ---
machine_processed_count=0
config_file_found_in_enabled_dir=false
for config_file in "$MACHINES_ENABLED_DIR"/*; do
  if [[ ! -f "$config_file" ]]; then
    # This handles the case where MACHINES_ENABLED_DIR is empty
    if [[ "$config_file" == "$MACHINES_ENABLED_DIR/*" ]]; then
        :
    else
        echo "WARN: Skipping non-file in MACHINES_ENABLED_DIR: $config_file" >&2
    fi
    continue
  fi
  config_file_found_in_enabled_dir=true

  current_user=""
  current_host=""
  backup_paths=()

  # --- Parse Individual Machine Configuration File ---
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}" # Remove comments
    line="${line#"${line%%[![:space:]]*}"}" # Trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"  # Trim trailing whitespace
    [[ -z "$line" ]] && continue

    # Identify machine section [user@host]
    if [[ "$line" =~ ^\[(.+)@(.+)\]$ ]]; then
      if [[ -n "$current_user" && -n "$current_host" ]]; then # Flush previous machine's paths
        flush_backup || echo "WARN: A problem occurred in flush_backup for $current_user@$current_host (file: $config_file), continuing." >&2
        backup_paths=()
      fi
      current_user="${BASH_REMATCH[1]}"
      current_host="${BASH_REMATCH[2]}"
      current_exclude="$EXCLUDES_DIR/$current_user@$current_host"
      echo ""
      echo "Processing machine: $current_user@$current_host from $config_file"
      machine_processed_count=$((machine_processed_count + 1))
      continue
    fi

    # Identify source paths
    if [[ "$line" == src=* && -n "$current_user" && -n "$current_host" ]]; then
      raw_path="${line#src=}"
      # eval is a potential security risk if $raw_path is not trusted
      expanded_path=$(eval echo "$raw_path")
      backup_paths+=("$expanded_path")
    fi
  done < "$config_file"

  # Flush any remaining paths for the last machine in the file
  if [[ -n "$current_user" && -n "$current_host" ]]; then
    flush_backup || echo "WARN: A problem occurred in flush_backup for $current_user@$current_host (end of file: $config_file), continuing." >&2
  fi
done

# --- Post-backup Summary and Hook Execution ---
if [[ "$config_file_found_in_enabled_dir" == false ]]; then
    echo "No machine configuration files found in $MACHINES_ENABLED_DIR."
elif [[ "$machine_processed_count" -eq 0 ]]; then
    echo "Machine configuration files were found, but no valid [user@host] sections were processed."
fi

# Check if any backups were actually processed to target directories
if [[ ${#target_machine_roots[@]} -eq 0 ]]; then
    if [[ "$machine_processed_count" -gt 0 ]]; then # Machines were defined but no targets created
        echo "Machines were processed, but no valid backup target directories were recorded. Skipping hooks."
    else # No machines were even defined or processed
        echo "No machines processed. Skipping hooks."
    fi
elif [[ -d "$HOOKS_DIR" ]]; then
  # --- Prepare and Uniquify Target Paths for Hooks ---
  declare -a hook_target_dirs_final=()
  for path_val in "${target_machine_roots[@]}"; do
    if [[ -d "$path_val" ]]; then # Ensure target dir still exists
      hook_target_dirs_final+=("$path_val")
    fi
  done
  
  # Create a unique list of directories that were backed up to.
  unique_final_paths=()
  if [[ ${#hook_target_dirs_final[@]} -gt 0 ]]; then
    IFS=$'\n' read -d '' -ra unique_final_paths < <(printf "%s\n" "${hook_target_dirs_final[@]}" | sort -u && printf '\0')
  fi

  # --- Iterate and Execute Enabled Hook Scripts ---
  if [[ ${#unique_final_paths[@]} -gt 0 ]]; then
    for hook in "$HOOKS_DIR"/*; do
      if [[ -f "$hook" && -x "$hook" ]]; then
        echo ""
        echo "Hooks: Running post-backup hook: $hook on targets: ${unique_final_paths[*]}"
        "$hook" "${unique_final_paths[@]}"
      elif [[ -f "$hook" ]]; then # File exists but not executable
        echo ""
        echo "Hooks: Skipping non-executable file hook: $hook"
      else # Not a file (e.g. broken symlink, subdirectory in hooks-enabled)
        echo ""
        echo "Hooks: Skipping non-file or non-executable item in hooks directory: $hook"
      fi
    done
  else
    echo ""
    echo "Hooks: No valid target directories available for hooks after processing."
  fi
else
  if [[ ! -d "$HOOKS_DIR" ]]; then # If HOOKS_DIR itself doesn't exist
    echo ""
    echo "Hooks: No hooks directory found at $HOOKS_DIR, or directory is empty."
  fi
fi
echo ""
echo "All operations complete."
