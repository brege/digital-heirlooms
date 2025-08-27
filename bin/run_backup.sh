#!/bin/bash
set -euo pipefail

# --- Project Configuration ---
PROJECT_NAME="digital-heirlooms"

# --- Script Path & Default Config Path ---
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_root_DEFAULT="$REPO_ROOT/config"

# --- Standard User Config Paths ---
USER_HOME_CFG_ROOT="$HOME/.config/$PROJECT_NAME"
USER_HOME_ENV_FILE="$USER_HOME_CFG_ROOT/backup.env"

# --- Argument Storage ---
config_root_override="" 

# This will hold the final, validated configuration root path
config_root=""

# --- print_usage function ---
print_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Runs the $PROJECT_NAME backup process based on the resolved configuration."
  echo ""
  echo "Options:"
  echo "  --config <path>        Specify the root directory for $PROJECT_NAME configurations."
  echo "                         This path should contain 'backup.env', 'machines-enabled/', etc."
  echo "                         Overrides default discovery logic."
  echo "  --help, -h             Show this help message."
  echo ""
  echo "Configuration Discovery Order (if --config is not used):"
  echo "  1. User specific: '$USER_HOME_CFG_ROOT' (via its backup.env or as the directory itself)."
  echo "  2. Repository default: '$config_root_DEFAULT' (via its backup.env or as the directory itself)."
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
        config_root_override="${args_to_process[$((idx + 1))]}"
        idx=$((idx + 1)) 
      else
        echo "WARN: --config flag found, but no value followed or value is another flag. Ignoring." >&2
      fi
      ;;
    --config=*)
      config_root_override="${arg_to_check#*=}"
      ;;
    -*)
      echo "ERROR: Unknown option: '$arg_to_check'." >&2
      print_usage
      exit 1
      ;;
    *)
      : # Ignore other arguments in this loop
      ;;
  esac
  ((idx++))
done

# --- Resolve Configuration Root Directory ---

# Helper to validate a config directory
_validate_config_dir() {
  local path="$1"
  local resolved_path

  if ! resolved_path="$(realpath "$path" 2>/dev/null)"; then
    return 1
  fi
  if [[ ! -d "$resolved_path" ]]; then
    return 1 
  fi
  echo "$resolved_path"
}

# Helper to try config discovery from env file redirect
_try_env_redirect() {
  local env_file="$1"
  local sourced_cfg_dir

  if [[ ! -f "$env_file" ]]; then
    return 1
  fi
  
  sourced_cfg_dir=$(CONFIG_DIR="" source "$env_file" >/dev/null 2>&1 && echo "${CONFIG_DIR:-}")
  if [[ -n "$sourced_cfg_dir" ]]; then
    if resolved_path=$(_validate_config_dir "$sourced_cfg_dir") && [[ -f "$resolved_path/backup.env" ]]; then
      echo "INFO: Using config redirected by '$env_file': '$resolved_path'"
      echo "$resolved_path"
      return 0
    fi
  fi
  return 1
}

# 3-tier config discovery
if [[ -n "$config_root_override" ]]; then
  # Tier 0: --config flag (strict validation, exit on failure)
  if ! resolved_path=$(_validate_config_dir "$config_root_override"); then
    echo "ERROR: Invalid --config path: '$config_root_override'" >&2
    exit 1
  fi
  if [[ ! -f "$resolved_path/backup.env" ]]; then
    echo "WARN: No backup.env in --config directory '$resolved_path'" >&2
  fi
  config_root="$resolved_path"
elif config_root=$(_try_env_redirect "$USER_HOME_ENV_FILE"); then
  # Tier 1a: User env file redirect
  :
elif resolved_path=$(_validate_config_dir "$USER_HOME_CFG_ROOT") && [[ -f "$resolved_path/backup.env" ]]; then
  # Tier 1b: User standard directory
  echo "INFO: Using user config directory '$resolved_path'"
  config_root="$resolved_path"
elif config_root=$(_try_env_redirect "$CONFIG_ROOT_DEFAULT/backup.env"); then
  # Tier 2a: Repo env file redirect  
  :
elif resolved_path=$(_validate_config_dir "$CONFIG_ROOT_DEFAULT") && [[ -f "$resolved_path/backup.env" ]]; then
  # Tier 2b: Repo default directory
  echo "INFO: Using repo default config directory '$resolved_path'" 
  config_root="$resolved_path"
fi

# --- Final Validation of Determined config_root ---
if [[ -z "$config_root" ]]; then
  echo "ERROR: Could not determine a valid $PROJECT_NAME configuration root directory." >&2
  echo "       Please use the --config option or ensure a valid setup exists (see '$0 --help' for discovery order)." >&2
  exit 1
fi

echo "INFO: Using config root: $config_root"

# --- Source Operational Environment File and Set Runtime Variables ---
env_file_to_source="$config_root/backup.env"
if [[ -f "$env_file_to_source" ]]; then
  echo "INFO: Sourcing environment: '$env_file_to_source'"
  set -a  
  source "$env_file_to_source"
  set +a
else
  echo "WARN: Operational environment file not found: '$env_file_to_source'." >&2
  echo "      Proceeding with default variable settings (DRY_RUN=true, empty target paths)." >&2
  DRY_RUN="${DRY_RUN:-true}" 
  LOCAL_TARGET_BASE="${LOCAL_TARGET_BASE:-}"
  REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
  LOCAL_ARCHIVE_BASE="${LOCAL_ARCHIVE_BASE:-}"
  REMOTE_ARCHIVE_BASE="${REMOTE_ARCHIVE_BASE:-}"
fi

# --- Define Core Operational Directories ---
machines_enabled_dir="$config_root/machines-enabled"
excludes_dir="$config_root/excludes" 
hooks_dir="$config_root/hooks-enabled"

echo "INFO: Machines: $machines_enabled_dir"
echo "INFO: Excludes: $excludes_dir"
echo "INFO: Hooks: $hooks_dir"

# --- Setup Global Rsync Exclude File ---
default_exclude_file="$excludes_dir/default.exclude"
if [[ -f "$default_exclude_file" ]]; then
  echo "INFO: Applying global excludes from: '$default_exclude_file'"
  default_exclude="$default_exclude_file"
else
  default_exclude=""
  echo "INFO: No global excludes found"
fi

# --- Initialize Core Backup Variables and State ---
REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
DRY_RUN="${DRY_RUN:-false}" # General default if not set by env file, or overridden if env file missing
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
  [[ ${#backup_paths[@]} -eq 0 ]] && return # Exit if no paths to back up for the current machine
  local staged_locally_this_flush=false

  # --- Iterate Over Source Paths for Current Machine ---
  for src_path in "${backup_paths[@]}"; do
    local rsync_cmd=(rsync -avzR --delete)
    if [[ -n "$default_exclude" && -f "$default_exclude" ]]; then
        rsync_cmd+=(--exclude-from="$default_exclude")
    fi
    if [[ -n "$current_exclude" && -f "$current_exclude" ]]; then
        echo "INFO: Using excludes: '$current_exclude'"
        rsync_cmd+=(--exclude-from="$current_exclude")
    elif [[ -n "$current_exclude" ]]; then 
        echo "WARN: Exclude file not found: '$current_exclude'" >&2
    fi

    # Determine backup destination and rsync parameters based on LOCAL/REMOTE TARGET_BASE variables
    # Scenario 1: Local staging then remote push
    if [[ -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"
      src_path_expanded=""
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
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      if [[ "$use_ssh" == true ]]; then
         rsync_cmd+=(-e ssh)
      fi
      rsync_cmd+=("$src_path_expanded" "$dest_dir")
      echo ""
      echo "Rsyncing to local staging ('$current_user@$current_host'):"
      echo "  Path: '$src_path_expanded' -> '$dest_dir'"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true

    # Scenario 2: Direct remote push
    elif [[ -z "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      dest_dir="$REMOTE_TARGET_BASE/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"
      
      # Check if source is local or remote
      if is_local_host "$current_host"; then
        src_path_expanded="$src_path"
        rsync_cmd+=("$src_path_expanded" "${dest_dir%/}/")
      else
        src_path_expanded="$current_user@$current_host:$src_path"
        rsync_cmd+=(-e ssh "$src_path_expanded" "${dest_dir%/}/")
      fi
      
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      echo ""
      echo "Rsyncing directly to remote ('$current_user@$current_host'):"
      echo "  Path: '$src_path_expanded' -> '${dest_dir%/}/'"
      "${rsync_cmd[@]}"

    # Scenario 3: Local staging only (REMOTE_TARGET_BASE is empty)
    else
      if [[ -z "$LOCAL_TARGET_BASE" ]]; then
        echo "ERROR: flush_backup: LOCAL_TARGET_BASE is not set for local backup of '$current_user@$current_host'. Skipping path '$src_path'." >&2
        continue
      fi
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"
      src_path_expanded=""
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
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      if [[ "$use_ssh" == true ]]; then
        rsync_cmd+=(-e ssh)
      fi
      rsync_cmd+=("$src_path_expanded" "$dest_dir")
      echo ""
      echo "Rsyncing to local destination ('$current_user@$current_host'):"
      echo "  Path: '$src_path_expanded' -> '$dest_dir'"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true
    fi
  done

  # --- Synchronize Staged Local Data to Remote Target (if applicable) ---
  if [[ "$staged_locally_this_flush" == true && -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
    local local_stage_path="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
    local remote_dest_path="$REMOTE_TARGET_BASE/$current_user@$current_host"
    echo ""
    echo "Syncing staged data for '$current_user@$current_host' to remote..."
    echo "  Path: '$local_stage_path/' -> '$remote_dest_path/'"
    local rsync_push_cmd=(rsync -az --delete --info=progress2)
    [[ "$DRY_RUN" == "true" ]] && rsync_push_cmd+=(--dry-run)
    rsync_push_cmd+=("$local_stage_path/" "$remote_dest_path/")
    "${rsync_push_cmd[@]}"
  fi

  backup_paths=()
  current_exclude="" 
}

# --- Main Processing Loop for Machines ---
machine_processed_count=0
config_file_found_in_enabled_dir=false
for config_file in "$machines_enabled_dir"/*; do
  if [[ ! -f "$config_file" ]]; then
    if [[ "$config_file" == "$machines_enabled_dir/*" ]]; then # Handles empty machines_enabled_dir
        : 
    else
        echo "WARN: Skipping non-file: '$config_file'" >&2
    fi
    continue
  fi
  config_file_found_in_enabled_dir=true

  current_user=""
  current_host=""
  backup_paths=()
  current_exclude="" 

  # --- Parse Individual Machine Configuration File ---
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}" 
    line="${line#"${line%%[![:space:]]*}"}" 
    line="${line%"${line##*[![:space:]]}"}"  
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[(.+)@(.+)\]$ ]]; then
      if [[ -n "$current_user" && -n "$current_host" ]]; then 
        flush_backup || echo "WARN: Backup failed for '$current_user@$current_host'" >&2
        backup_paths=()
        current_exclude="" 
      fi
      current_user="${BASH_REMATCH[1]}"
      current_host="${BASH_REMATCH[2]}"
      echo ""
      echo "Processing machine: '$current_user@$current_host' from config file: '$config_file'"
      machine_processed_count=$((machine_processed_count + 1))
      continue 
    fi

    if [[ "$line" == src=* && -n "$current_user" && -n "$current_host" ]]; then
      raw_path="${line#src=}"
      # eval is a potential security risk if content of $raw_path from config file is not trusted.
      expanded_path=$(eval echo "$raw_path")
      backup_paths+=("$expanded_path")
    fi
    
    if [[ "$line" == exclude-from=* && -n "$current_user" && -n "$current_host" ]]; then
      exclude_path_from_file="${line#exclude-from=}"
      resolved_exclude_path=""
      if [[ "$exclude_path_from_file" != /* && -n "$config_root" ]]; then
        if [[ "$exclude_path_from_file" == "$config_root"* ]]; then
            resolved_exclude_path="$exclude_path_from_file"
        else
            resolved_exclude_path="$config_root/$exclude_path_from_file"
        fi
      else
        resolved_exclude_path="$exclude_path_from_file" 
      fi
      
      if [[ -n "$resolved_exclude_path" ]]; then
        if ! temp_resolved_path="$(realpath "$resolved_exclude_path" 2>/dev/null)"; then
          echo "WARN: Invalid exclude path for '$current_user@$current_host': '$resolved_exclude_path'" >&2
          current_exclude="" 
        else
          current_exclude="$temp_resolved_path"
        fi
      else
          current_exclude="" 
      fi
    fi
  done < "$config_file"

  if [[ -n "$current_user" && -n "$current_host" ]]; then
    flush_backup || echo "WARN: Backup failed for '$current_user@$current_host'" >&2
  fi
done

# --- Post-backup Summary and Hook Execution ---
if [[ "$config_file_found_in_enabled_dir" == false ]]; then
    echo "INFO: No machine configs found"
elif [[ "$machine_processed_count" -eq 0 ]]; then
    echo "INFO: No valid machine sections processed"
fi

if [[ ${#target_machine_roots[@]} -eq 0 ]]; then
    if [[ "$machine_processed_count" -gt 0 ]]; then 
        echo "INFO: No valid targets recorded, skipping hooks"
    else 
        echo "INFO: No machines processed, skipping hooks"
    fi
elif [[ -d "$hooks_dir" ]]; then
  # --- Prepare and Uniquify Target Paths for Hooks ---
  declare -a hook_target_dirs_final=()
  for path_val in "${target_machine_roots[@]}"; do
    # Include both local directories and remote paths for hooks
    if [[ -d "$path_val" || "$path_val" == *":"* ]]; then 
      hook_target_dirs_final+=("$path_val")
    fi
  done
  
  unique_final_paths=()
  if [[ ${#hook_target_dirs_final[@]} -gt 0 ]]; then
    IFS=$'\n' read -d '' -ra unique_final_paths < <(printf "%s\n" "${hook_target_dirs_final[@]}" | sort -u && printf '\0')
  fi

  # --- Iterate and Execute Enabled Hook Scripts ---
  if [[ ${#unique_final_paths[@]} -gt 0 ]]; then
    for hook in "$hooks_dir"/*; do
      if [[ -f "$hook" && -x "$hook" ]]; then
        echo ""
        echo "Hooks: Running post-backup hook: '$hook' on targets: ${unique_final_paths[*]}"
        "$hook" "${unique_final_paths[@]}"
      elif [[ -f "$hook" ]]; then 
        echo ""
        echo "WARN: Hook not executable: '$hook'" >&2
      else 
        echo ""
        echo "INFO: Skipping non-executable: '$hook'"
      fi
    done
  else
    echo ""
    echo "INFO: No valid targets for hooks"
  fi
else
  if [[ ! -d "$hooks_dir" ]]; then 
    echo ""
    echo "INFO: No hooks directory found"
  fi
fi
echo ""
echo "All backup operations complete." # Slightly rephrased
