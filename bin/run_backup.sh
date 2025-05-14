#!/bin/bash
set -euo pipefail

# ----------------------------------------
# 🧭 Resolve script base and config dir
# ----------------------------------------

BACKUPKIT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_ROOT_DEFAULT="$BACKUPKIT_HOME/config" # Default if no --config and no CONFIG_DIR in repo's backup.env
CONFIG_ROOT="$CONFIG_ROOT_DEFAULT"           # Initial assumption

# --- Argument parsing for --config ---
CONFIG_ROOT_OVERRIDE=""
# More robust argument parsing for --config VALUE and --config=VALUE
# Create a temporary array from $@ to safely shift and inspect
args_to_process=("$@")
idx=0
while [[ $idx -lt ${#args_to_process[@]} ]]; do
  arg_to_check="${args_to_process[$idx]}"
  case "$arg_to_check" in
    --config)
      if [[ -n "${args_to_process[$((idx + 1))]:-}" && "${args_to_process[$((idx + 1))]}" != --* ]]; then
        CONFIG_ROOT_OVERRIDE="${args_to_process[$((idx + 1))]}"
        # Conceptually consume both arguments by advancing idx appropriately or breaking if only --config is parsed
        idx=$((idx + 1)) # Advance past value
      else
        echo "[WARN] --config flag found, but no value followed or value is another flag. Ignoring." >&2
      fi
      ;;
    --config=*)
      CONFIG_ROOT_OVERRIDE="${arg_to_check#*=}"
      ;;
    *)
      # Other arguments can be processed here if run_backup.sh takes more options
      # For now, we only care about --config
      ;;
  esac
  ((idx++))
done

if [[ -n "$CONFIG_ROOT_OVERRIDE" ]]; then
  # --config was provided, use its value directly
  if ! CONFIG_ROOT="$(realpath "$CONFIG_ROOT_OVERRIDE")"; then
    echo "[ERROR] Invalid path specified with --config: $CONFIG_ROOT_OVERRIDE" >&2
    exit 1
  fi
  # When --config is used, this CONFIG_ROOT is authoritative.
  # We will source backup.env from *this* CONFIG_ROOT.
  # We do NOT want CONFIG_DIR from that backup.env to then change CONFIG_ROOT again.
  _USER_CONFIG_DIR_EFFECTIVELY_SET_BY_FLAG=true # Helper flag
else
  # No --config, use default logic:
  # Check if the REPO's default backup.env specifies a user CONFIG_DIR
  DEFAULT_REPO_ENV_FILE="$CONFIG_ROOT_DEFAULT/backup.env"
  if [[ -f "$DEFAULT_REPO_ENV_FILE" ]]; then
    # Source into a subshell to safely extract CONFIG_DIR
    USER_SPECIFIC_CONFIG_DIR_FROM_DEFAULT_ENV=$( (source "$DEFAULT_REPO_ENV_FILE" >/dev/null 2>&1 && echo "$CONFIG_DIR") )
    if [[ -n "$USER_SPECIFIC_CONFIG_DIR_FROM_DEFAULT_ENV" ]]; then
      if ! CONFIG_ROOT="$(realpath "$USER_SPECIFIC_CONFIG_DIR_FROM_DEFAULT_ENV")"; then
        echo "[ERROR] Invalid CONFIG_DIR specified in $DEFAULT_REPO_ENV_FILE: $USER_SPECIFIC_CONFIG_DIR_FROM_DEFAULT_ENV" >&2
        exit 1
      fi
    fi
  fi
  _USER_CONFIG_DIR_EFFECTIVELY_SET_BY_FLAG=false # Helper flag
fi

# Now, CONFIG_ROOT is definitively set.
# Source the backup.env from this final CONFIG_ROOT.
ENV_FILE_TO_SOURCE="$CONFIG_ROOT/backup.env"
if [[ -f "$ENV_FILE_TO_SOURCE" ]]; then
  set -a  # Auto-export all variables from this env file
  _TEMP_CONFIG_DIR_BEFORE_SOURCE="${CONFIG_DIR:-}" 
  source "$ENV_FILE_TO_SOURCE"
  set +a
  if [[ "$_USER_CONFIG_DIR_EFFECTIVELY_SET_BY_FLAG" == true ]]; then
      CONFIG_DIR="${_TEMP_CONFIG_DIR_BEFORE_SOURCE}" 
  elif [[ -n "${CONFIG_DIR:-}" && "$CONFIG_ROOT" != "$(realpath "${CONFIG_DIR}")" ]]; then
      if ! CONFIG_ROOT="$(realpath "${CONFIG_DIR}")"; then
          echo "[ERROR] Invalid CONFIG_DIR specified in $ENV_FILE_TO_SOURCE: ${CONFIG_DIR}" >&2
          exit 1
      fi
  fi
else
  echo "[WARN] Environment file not found: $ENV_FILE_TO_SOURCE. Critical variables (DRY_RUN, target paths) may be unset." >&2
  DRY_RUN="${DRY_RUN:-true}" 
  LOCAL_TARGET_BASE="${LOCAL_TARGET_BASE:-}"
  REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
  LOCAL_ARCHIVE_BASE="${LOCAL_ARCHIVE_BASE:-}"
  REMOTE_ARCHIVE_BASE="${REMOTE_ARCHIVE_BASE:-}"
fi

# Derived paths from the final CONFIG_ROOT
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
EXCLUDES_DIR="$CONFIG_ROOT/excludes"
HOOKS_DIR="$CONFIG_ROOT/hooks-enabled"

echo "Backup Engine: Using machine configs from: $MACHINES_ENABLED_DIR"
echo "Backup Engine: Using excludes from: $EXCLUDES_DIR"
echo "Backup Engine: Using hooks from: $HOOKS_DIR"

# Setup rsync's default exclude file
_DEFAULT_EXCLUDE_FILE_PATH="$EXCLUDES_DIR/default.exclude"
if [[ -f "$_DEFAULT_EXCLUDE_FILE_PATH" ]]; then
  echo "Backup Engine: Applying global excludes from: $_DEFAULT_EXCLUDE_FILE_PATH"
  default_exclude="$_DEFAULT_EXCLUDE_FILE_PATH" 
else
  default_exclude=""
  echo "Backup Engine: No global exclude file found at $_DEFAULT_EXCLUDE_FILE_PATH (this is okay)."
fi


REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}" 
DRY_RUN="${DRY_RUN:-false}"                  

direct_remote_rsync=false 
staged_dirs=()           

current_user=""
current_host=""
current_exclude=""
backup_paths=()
declare -A target_machine_roots 

is_local_host() {
  [[ "$1" == "localhost" || "$1" == "$(hostname)" || "$1" == "$(hostname -f)" ]]
}

flush_backup() {
  [[ ${#backup_paths[@]} -eq 0 ]] && return

  local staged_locally_this_flush=false 

  for src_path in "${backup_paths[@]}"; do
    # Construct rsync_cmd with consistent exclude handling
    local rsync_cmd=(rsync -avzR --delete) # Initialize with base options

    # Add global exclude file if path is set and file exists
    if [[ -n "$default_exclude" && -f "$default_exclude" ]]; then
        rsync_cmd+=(--exclude-from="$default_exclude")
    fi
    # Add machine-specific exclude file if path is set and file exists
    # - Note: this is the file the user edits while using the
    #   ./bloatscan.sh whittle, or some other manifesting method
    if [[ -n "$current_exclude" && -f "$current_exclude" ]]; then
        rsync_cmd+=(--exclude-from="$current_exclude")
    fi

    # Scenario 1: Local staging then remote push
    if [[ -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir"

      # Determine whether to use ssh or not
      src_path_expanded=""
      if is_local_host "$current_host"; then 
        use_ssh=false
        src_path_expanded="$src_path"
      else
        use_ssh=true
        src_path_expanded="$current_user@$current_host:$src_path" 
      fi
      
      mkdir -p "$dest_dir"

      # Prevent recursion: Exclude the local target base
      if [[ "$LOCAL_TARGET_BASE" == /* ]]; then # Ensure it's an absolute path
          rsync_cmd+=(--exclude "$LOCAL_TARGET_BASE")
      fi

      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      $use_ssh && rsync_cmd+=(-e ssh)
      rsync_cmd+=("$src_path_expanded" "$dest_dir")

      echo 
      echo "Backup Engine: Rsyncing to local staging ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $dest_dir"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true

    # Scenario 2: Direct remote push
    elif [[ -z "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      dest_dir="$REMOTE_TARGET_BASE/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir" 
      
      src_path_expanded="$current_user@$current_host:$src_path"
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      rsync_cmd+=(-e ssh "$src_path_expanded" "${dest_dir%/}/") 

      echo 
      echo "Backup Engine: Rsyncing directly to remote ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> ${dest_dir%/}/"
      "${rsync_cmd[@]}"

    # Scenario 3: Local staging only (REMOTE_TARGET_BASE is empty)
    else 
      if [[ -z "$LOCAL_TARGET_BASE" ]]; then
        echo "[ERROR] flush_backup: LOCAL_TARGET_BASE is not set for local backup of $current_user@$current_host. Skipping path $src_path." >&2
        continue
      fi
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir" 

      src_path_expanded=""
      if is_local_host "$current_host"; then 
        use_ssh=false
        src_path_expanded="$src_path"
      else 
        use_ssh=true
        src_path_expanded="$current_user@$current_host:$src_path" 
      fi

      mkdir -p "$dest_dir"
      if [[ "$LOCAL_TARGET_BASE" == /* ]]; then # Ensure it's an absolute path
          rsync_cmd+=(--exclude "$LOCAL_TARGET_BASE")
      fi

      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      $use_ssh && rsync_cmd+=(-e ssh)
      rsync_cmd+=("$src_path_expanded" "$dest_dir")

      echo 
      echo "Backup Engine: Rsyncing to local destination ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $dest_dir"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true 
    fi
  done

  if [[ "$staged_locally_this_flush" == true && -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
    local local_stage_path="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
    local remote_dest_path="$REMOTE_TARGET_BASE/$current_user@$current_host"

    echo # for spacing
    echo "Backup Engine: Syncing staged data for $current_user@$current_host to remote..."
    echo "Path: $local_stage_path/ -> $remote_dest_path/"
   
    # Execute rsync
    local rsync_push_cmd=(rsync -az --delete) 
    # Optional: Apply excludes to the push as well, if desired
    # if [[ -n "$default_exclude" && -f "$default_exclude" ]]; then 
    #   rsync_push_cmd+=(--exclude-from="$default_exclude")
    # fi
    # if [[ -n "$current_exclude" && -f "$current_exclude" ]]; then
    #   rsync_push_cmd+=(--exclude-from="$current_exclude")
    # fi
    [[ "$DRY_RUN" == "true" ]] && rsync_push_cmd+=(--dry-run)
    rsync_push_cmd+=("$local_stage_path/" "$remote_dest_path/") 
    "${rsync_push_cmd[@]}"
  fi

  backup_paths=() 
  current_exclude=""
}

machine_processed_count=0
config_file_found_in_enabled_dir=false # To improve end-of-script info messages
for config_file in "$MACHINES_ENABLED_DIR"/*; do
  if [[ ! -f "$config_file" ]]; then
    if [[ "$config_file" == "$MACHINES_ENABLED_DIR/*" ]]; then
        # This handles the case where MACHINES_ENABLED_DIR is empty
        : 
    else
        echo "[WARN] Skipping non-file in MACHINES_ENABLED_DIR: $config_file" >&2
    fi
    continue 
  fi
  config_file_found_in_enabled_dir=true
  
  current_user="" 
  current_host=""
  backup_paths=() 

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue 

    if [[ "$line" =~ ^\[(.+)@(.+)\]$ ]]; then
      if [[ -n "$current_user" && -n "$current_host" ]]; then 
        flush_backup || echo "[WARN] A problem occurred in flush_backup for $current_user@$current_host (file: $config_file), continuing." >&2
        backup_paths=() 
      fi
      current_user="${BASH_REMATCH[1]}"
      current_host="${BASH_REMATCH[2]}"
      current_exclude="$EXCLUDES_DIR/$current_user@$current_host"
      echo
      echo "Backup Engine: Processing machine: $current_user@$current_host from $config_file"
      machine_processed_count=$((machine_processed_count + 1))
      continue
    fi

    if [[ "$line" == src=* && -n "$current_user" && -n "$current_host" ]]; then
      raw_path="${line#src=}"
      expanded_path=$(eval echo "$raw_path")
      backup_paths+=($expanded_path)
    fi
  done < "$config_file"
  

  if [[ -n "$current_user" && -n "$current_host" ]]; then
    flush_backup || echo "[WARN] A problem occurred in flush_backup for $current_user@$current_host (end of file: $config_file), continuing." >&2
  fi
done

if [[ "$config_file_found_in_enabled_dir" == false ]]; then # If glob didn't expand
    echo "[INFO] No machine configuration files found in $MACHINES_ENABLED_DIR."
elif [[ "$machine_processed_count" -eq 0 ]]; then # Files found, but no [user@host] sections
    echo "[INFO] Machine configuration files were found, but no valid [user@host] sections were processed."
fi

if [[ ${#target_machine_roots[@]} -eq 0 ]]; then
    if [[ "$machine_processed_count" -gt 0 ]]; then
        echo "[INFO] Machines were processed, but no valid backup target directories were recorded. Skipping hooks."
    else
        echo "[INFO] No machines processed. Skipping hooks."
    fi
elif [[ -d "$HOOKS_DIR" ]]; then
  declare -a hook_target_dirs_final=()
  for path_val in "${target_machine_roots[@]}"; do 
    if [[ -d "$path_val" ]]; then 
      hook_target_dirs_final+=("$path_val")
    fi
  done
  IFS=$'\n' read -d '' -ra unique_final_paths < <(printf "%s\n" "${hook_target_dirs_final[@]}" | sort -u && printf '\0')

  if [[ ${#unique_final_paths[@]} -gt 0 ]]; then
    for hook in "$HOOKS_DIR"/*; do 
      if [[ -f "$hook" && -x "$hook" ]]; then
        echo
        echo "Hooks: Running post-backup hook: $hook on targets: ${unique_final_paths[*]}"
        "$hook" "${unique_final_paths[@]}"
      elif [[ -f "$hook" ]]; then 
        echo
        echo "Hooks: Skipping non-executable file hook: $hook"
      else 
        echo
        echo "Hooks: Skipping non-file or non-executable item in hooks directory: $hook"
      fi
    done
  else 
    echo
    echo "Hooks: No valid target directories available for hooks after processing."
  fi
else 
  if [[ ! -d "$HOOKS_DIR" ]]; then # Only print if HOOKS_DIR itself is missing
    echo
    echo "Hooks: No hooks directory found at $HOOKS_DIR, or directory is empty."
  fi
fi
echo
echo "Backup Engine: All operations complete."

