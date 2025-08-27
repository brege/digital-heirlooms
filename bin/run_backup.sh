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

# --- Resolve Final Configuration Root Directory (Unified 3-Tier + Flag Logic) ---

# --- Helper function to check a potential config directory ---
CONFIG_CANDIDATE_REALPATH=""
_try_set_config_root() {
  local path_to_check="$1"
  local description="$2"
  local temp_realpath

  if ! temp_realpath="$(realpath "$path_to_check" 2>/dev/null)"; then
    echo "WARN: $description: Path '$path_to_check' is invalid (realpath failed). Will be ignored." >&2 # Clarified
    return 1
  fi
  if [[ ! -d "$temp_realpath" ]]; then
    echo "WARN: $description: Path '$temp_realpath' is not a directory. Will be ignored." >&2 # Clarified
    return 1
  fi
  if [[ ! -f "$temp_realpath/backup.env" ]]; then
    echo "WARN: $description: Directory '$temp_realpath' does not contain a 'backup.env' file. Will be ignored for auto-discovery." >&2 # Clarified
    return 1
  fi
  CONFIG_CANDIDATE_REALPATH="$temp_realpath"
  return 0
}

# --- Tier 0: Check for Explicit --config Argument ---
if [[ -n "$CONFIG_ROOT_OVERRIDE" ]]; then
  echo "INFO: --config flag provided. Attempting to use specified path: '$CONFIG_ROOT_OVERRIDE'" # Clarified
  cfg_realpath_tmp="" 
  if ! cfg_realpath_tmp="$(realpath "$CONFIG_ROOT_OVERRIDE" 2>/dev/null)"; then
    echo "ERROR: Invalid path specified with --config: '$CONFIG_ROOT_OVERRIDE' (realpath resolution failed)." >&2
    exit 1
  fi
  if [[ ! -d "$cfg_realpath_tmp" ]]; then
    echo "ERROR: Path specified with --config is not a directory: '$cfg_realpath_tmp'." >&2
    exit 1
  fi
  if [[ ! -f "$cfg_realpath_tmp/backup.env" ]]; then
    echo "WARN: Directory specified with --config ('$cfg_realpath_tmp') does not contain a 'backup.env' file." >&2
    echo "      Proceeding, but essential configuration variables (like DRY_RUN, target paths) might be missing or use defaults." >&2
  fi
  CONFIG_ROOT="$cfg_realpath_tmp"
fi

# --- Tier 1: Check User's Standard Configuration ($USER_HOME_CFG_ROOT) ---
if [[ -z "$CONFIG_ROOT" ]]; then 
  # --- Tier 1a: Check for CONFIG_DIR in $USER_HOME_ENV_FILE ---
  if [[ -f "$USER_HOME_ENV_FILE" ]]; then 
    sourced_cfg_dir=$(CONFIG_DIR="" source "$USER_HOME_ENV_FILE" >/dev/null 2>&1 && echo "${CONFIG_DIR:-}")
    if [[ -n "$sourced_cfg_dir" ]]; then 
      echo "INFO: Found CONFIG_DIR in '$USER_HOME_ENV_FILE', points to: '$sourced_cfg_dir'"
      if _try_set_config_root "$sourced_cfg_dir" "Path from CONFIG_DIR in '$USER_HOME_ENV_FILE'"; then
        CONFIG_ROOT="$CONFIG_CANDIDATE_REALPATH"
        echo "INFO: Using configuration root redirected by '$USER_HOME_ENV_FILE': '$CONFIG_ROOT'"
      fi
    fi
  fi
  # --- Tier 1b: Check $USER_HOME_CFG_ROOT directory itself ---
  if [[ -z "$CONFIG_ROOT" ]]; then 
    if _try_set_config_root "$USER_HOME_CFG_ROOT" "User standard directory '$USER_HOME_CFG_ROOT'"; then
      CONFIG_ROOT="$CONFIG_CANDIDATE_REALPATH"
      echo "INFO: Using user's standard configuration directory '$CONFIG_ROOT' (backup.env present)."
    fi
  fi
fi

# --- Tier 2: Check Repository's Default Configuration ($CONFIG_ROOT_DEFAULT) ---
if [[ -z "$CONFIG_ROOT" ]]; then 
  REPO_DEFAULT_ENV_FILE="$CONFIG_ROOT_DEFAULT/backup.env"
  # --- Tier 2a: Check for CONFIG_DIR in $REPO_DEFAULT_ENV_FILE ---
  if [[ -f "$REPO_DEFAULT_ENV_FILE" ]]; then 
    sourced_cfg_dir=$(CONFIG_DIR="" source "$REPO_DEFAULT_ENV_FILE" >/dev/null 2>&1 && echo "${CONFIG_DIR:-}")
    if [[ -n "$sourced_cfg_dir" ]]; then 
      echo "INFO: Found CONFIG_DIR in '$REPO_DEFAULT_ENV_FILE', points to: '$sourced_cfg_dir'"
      if _try_set_config_root "$sourced_cfg_dir" "Path from CONFIG_DIR in '$REPO_DEFAULT_ENV_FILE'"; then
        CONFIG_ROOT="$CONFIG_CANDIDATE_REALPATH"
        echo "INFO: Using configuration root redirected by '$REPO_DEFAULT_ENV_FILE': '$CONFIG_ROOT'"
      fi
    fi
  fi
  # --- Tier 2b: Check $CONFIG_ROOT_DEFAULT directory itself ---
  if [[ -z "$CONFIG_ROOT" ]]; then 
    if _try_set_config_root "$CONFIG_ROOT_DEFAULT" "Repository default directory '$CONFIG_ROOT_DEFAULT'"; then
      CONFIG_ROOT="$CONFIG_CANDIDATE_REALPATH"
      echo "INFO: Using repository default configuration directory '$CONFIG_ROOT' (backup.env present)."
    fi
  fi
fi

# --- Final Validation of Determined CONFIG_ROOT ---
if [[ -z "$CONFIG_ROOT" ]]; then
  echo "ERROR: Could not determine a valid $PROJECT_NAME configuration root directory." >&2
  echo "       Please use the --config option or ensure a valid setup exists (see '$0 --help' for discovery order)." >&2
  exit 1
fi

echo "INFO: Effective configuration root will be: $CONFIG_ROOT" # Clarified this is the decision point

# --- Source Operational Environment File and Set Runtime Variables ---
ENV_FILE_TO_SOURCE="$CONFIG_ROOT/backup.env"
if [[ -f "$ENV_FILE_TO_SOURCE" ]]; then
  echo "INFO: Sourcing operational environment file: '$ENV_FILE_TO_SOURCE'" # Quoted path
  set -a  
  source "$ENV_FILE_TO_SOURCE"
  set +a
else
  echo "WARN: Operational environment file not found: '$ENV_FILE_TO_SOURCE'." >&2
  echo "      Proceeding with default variable settings (DRY_RUN=true, empty target paths)." >&2
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

echo "INFO: Using machine configurations from: '$MACHINES_ENABLED_DIR'"
echo "INFO: Using global excludes from directory: '$EXCLUDES_DIR'"
echo "INFO: Using hooks from: '$HOOKS_DIR'"

# --- Setup Global Rsync Exclude File ---
dflt_exclude_path="$EXCLUDES_DIR/default.exclude"
if [[ -f "$dflt_exclude_path" ]]; then
  echo "INFO: Applying global excludes from: '$dflt_exclude_path'"
  default_exclude="$dflt_exclude_path"
else
  default_exclude=""
  echo "INFO: No global exclude file found at '$dflt_exclude_path' (this is okay)." # Changed from "No ... found" to "INFO: No..."
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
        echo "INFO: Applying machine-specific excludes for '$current_user@$current_host' from: '$current_exclude'"
        rsync_cmd+=(--exclude-from="$current_exclude")
    elif [[ -n "$current_exclude" ]]; then 
        echo "WARN: Machine-specific exclude file specified ('$current_exclude') but not found for '$current_user@$current_host'. Proceeding without it." >&2
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
      
      if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$dest_dir"
      elif [[ ! -d "$dest_dir" ]]; then 
        echo "[DRY RUN] Would create directory: '$dest_dir'"
      fi

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
      
      if [[ "$DRY_RUN" == "true" ]]; then
        rsync_cmd+=(--dry-run)
      fi
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

      if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$dest_dir"
      elif [[ ! -d "$dest_dir" ]]; then
        echo "[DRY RUN] Would create directory: '$dest_dir'"
      fi

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
    if [[ "$config_file" == "$MACHINES_ENABLED_DIR/*" ]]; then # Handles empty MACHINES_ENABLED_DIR
        : 
    else
        echo "WARN: Skipping non-file in MACHINES_ENABLED_DIR: '$config_file'" >&2
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
        flush_backup || echo "WARN: A problem occurred in flush_backup for '$current_user@$current_host' (from file '$config_file'), continuing." >&2
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
      if [[ "$exclude_path_from_file" != /* && -n "$CONFIG_ROOT" ]]; then
        if [[ "$exclude_path_from_file" == "$CONFIG_ROOT"* ]]; then
            resolved_exclude_path="$exclude_path_from_file"
        else
            resolved_exclude_path="$CONFIG_ROOT/$exclude_path_from_file"
        fi
      else
        resolved_exclude_path="$exclude_path_from_file" 
      fi
      
      if [[ -n "$resolved_exclude_path" ]]; then
        exclude_realpath_tmp=""
        if ! exclude_realpath_tmp="$(realpath "$resolved_exclude_path" 2>/dev/null)"; then
          echo "WARN: Invalid path in 'exclude-from' for '$current_user@$current_host': '$resolved_exclude_path' (realpath failed). No machine-specific exclude will be used." >&2
          current_exclude="" 
        else
          current_exclude="$exclude_realpath_tmp"
        fi
      else
          current_exclude="" 
      fi
    fi
  done < "$config_file"

  if [[ -n "$current_user" && -n "$current_host" ]]; then
    flush_backup || echo "WARN: A problem occurred in flush_backup for '$current_user@$current_host' (end of file '$config_file'), continuing." >&2
  fi
done

# --- Post-backup Summary and Hook Execution ---
if [[ "$config_file_found_in_enabled_dir" == false ]]; then
    echo "INFO: No machine configuration files found in '$MACHINES_ENABLED_DIR'." # Changed to INFO
elif [[ "$machine_processed_count" -eq 0 ]]; then
    echo "INFO: Machine configuration files were found in '$MACHINES_ENABLED_DIR', but no valid [user@host] sections were processed." # Changed to INFO
fi

if [[ ${#target_machine_roots[@]} -eq 0 ]]; then
    if [[ "$machine_processed_count" -gt 0 ]]; then 
        echo "INFO: Machines were processed, but no valid backup target directories were recorded. Skipping hooks." # Changed to INFO
    else 
        echo "INFO: No machines processed. Skipping hooks." # Changed to INFO
    fi
elif [[ -d "$HOOKS_DIR" ]]; then
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
    for hook in "$HOOKS_DIR"/*; do
      if [[ -f "$hook" && -x "$hook" ]]; then
        echo ""
        echo "Hooks: Running post-backup hook: '$hook' on targets: ${unique_final_paths[*]}"
        "$hook" "${unique_final_paths[@]}"
      elif [[ -f "$hook" ]]; then 
        echo ""
        echo "WARN: Hook file '$hook' is not executable. Skipping." >&2 # Changed to WARN
      else 
        echo ""
        echo "INFO: Skipping non-file or non-executable item in hooks directory: '$hook'" # Changed to INFO
      fi
    done
  else
    echo ""
    echo "INFO: No valid target directories available for hooks after processing." # Changed to INFO
  fi
else
  if [[ ! -d "$HOOKS_DIR" ]]; then 
    echo ""
    echo "INFO: Hooks directory not found at '$HOOKS_DIR', or directory is empty. Skipping hook execution." # Changed to INFO
  fi
fi
echo ""
echo "All backup operations complete." # Slightly rephrased
