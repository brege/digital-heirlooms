#!/bin/bash
set -euo pipefail

# ----------------------------------------
# 🧭 Resolve script base and config dir
# ----------------------------------------

BACKUPKIT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_ROOT_DEFAULT="$BACKUPKIT_HOME/config"
CONFIG_ROOT="$CONFIG_ROOT_DEFAULT"

# Check for --config=/some/path
for arg in "$@"; do
  case $arg in
    --config=*)
      CONFIG_ROOT="$(realpath "${arg#*=}")"
      shift
      ;;
  esac
done

# Try to source backup.env and let it override CONFIG_ROOT via CONFIG_DIR
ENV_FILE="$CONFIG_ROOT_DEFAULT/backup.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a  # Auto-export all variables
  source "$ENV_FILE"
  set +a
  CONFIG_ROOT="${CONFIG_DIR:-$CONFIG_ROOT}"
fi

# Derived paths
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
EXCLUDES_DIR="$CONFIG_ROOT/excludes"
HOOKS_DIR="$CONFIG_ROOT/hooks-enabled"

echo "Backup Engine: Using machine configs from: $MACHINES_ENABLED_DIR"
echo "Backup Engine: Using excludes from: $EXCLUDES_DIR"

DEFAULT_EXCLUDE="$EXCLUDES_DIR/default.exclude"
# echo "$DEFAULT_EXCLUDE" # Commented out: Potentially a debug line
if [[ -f "$DEFAULT_EXCLUDE" ]]; then
  echo "Backup Engine: Applying global excludes from: $DEFAULT_EXCLUDE"
  default_exclude="--exclude-from=$DEFAULT_EXCLUDE"
else
  default_exclude=""
fi


REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
DRY_RUN="${DRY_RUN:-false}"
direct_remote_rsync_performed_for_machine=false # Tracks if direct remote rsync happened for current machine
staged_locally_for_machine=false # Tracks if current machine data was staged locally

current_user=""
current_host=""
current_exclude=""
backup_paths=()

# This associative array will store the root backup directory for each machine
# Key: "user@host", Value: "/path/to/backup_root_for_user@host"
declare -A target_machine_roots 

is_local_host() {
  [[ "$1" == "localhost" || "$1" == "$(hostname)" || "$1" == "$(hostname -f)" ]]
}

# This function processes backup paths for the current_user@current_host
flush_backup() {
  [[ ${#backup_paths[@]} -eq 0 ]] && return

  # Reset flags for the current machine processing
  direct_remote_rsync_performed_for_machine=false
  staged_locally_for_machine=false
  local machine_backup_root="" # Specific to this flush_backup call

  for src_path in "${backup_paths[@]}"; do
    # Scenario 1: Local staging area defined, AND remote target defined
    # Action: Backup to local staging, then rsync staged data to remote.
    if [[ -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      machine_backup_root="${LOCAL_TARGET_BASE%/}/$current_user@$current_host" # Store local stage as the primary root for this machine
      target_machine_roots["$current_user@$current_host"]="$machine_backup_root"

      src_path_expanded=""
      if is_local_host "$current_host"; then
        use_ssh=false
        src_path_expanded="$src_path"
      else
        use_ssh=true
        src_path_expanded="$current_user@$current_host:$src_path"
      fi

      mkdir -p "$machine_backup_root"

      rsync_cmd=(rsync -avzR --delete $default_exclude)
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_cmd+=(--exclude-from="$current_exclude")
      $use_ssh && rsync_cmd+=(-e ssh)
      rsync_cmd+=("$src_path_expanded" "$machine_backup_root")

      echo # for spacing
      echo "Backup Engine: Rsyncing to local staging ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $machine_backup_root"
      # echo "Command: ${rsync_cmd[*]}" # Potentially verbose, enable if needed for debug
      "${rsync_cmd[@]}"
      staged_locally_for_machine=true

    # Scenario 2: NO local staging, ONLY remote target defined
    # Action: Backup directly to remote.
    elif [[ -z "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      machine_backup_root="$REMOTE_TARGET_BASE/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$machine_backup_root"
      
      src_path_expanded="$current_user@$current_host:$src_path" # Assume src_path is on the remote, so prefix

      rsync_cmd=(rsync -avzR --delete $default_exclude)
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_cmd+=(--exclude-from="$current_exclude")
      rsync_cmd+=(-e ssh "$src_path_expanded" "$machine_backup_root/") # Note: target ends with /

      echo # for spacing
      echo "Backup Engine: Rsyncing directly to remote ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $machine_backup_root/"
      # echo "Command: ${rsync_cmd[*]}" # Potentially verbose
      "${rsync_cmd[@]}"
      direct_remote_rsync_performed_for_machine=true
      
    # Scenario 3: LOCAL_TARGET_BASE defined, but REMOTE_TARGET_BASE is not (or other fallback)
    # Action: Backup to local target only.
    else
      machine_backup_root="${LOCAL_TARGET_BASE:-$HOME/Backup}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$machine_backup_root"

      src_path_expanded=""
      if is_local_host "$current_host"; then
        use_ssh=false
        src_path_expanded="$src_path"
      else
        use_ssh=true
        src_path_expanded="$current_user@$current_host:$src_path"
      fi

      mkdir -p "$machine_backup_root"

      rsync_cmd=(rsync -avzR --delete $default_exclude)
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_cmd+=(--exclude-from="$current_exclude")
      $use_ssh && rsync_cmd+=(-e ssh)
      rsync_cmd+=("$src_path_expanded" "$machine_backup_root")

      echo # for spacing
      echo "Backup Engine: Rsyncing to local destination ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $machine_backup_root"
      # echo "Command: ${rsync_cmd[*]}" # Potentially verbose
      "${rsync_cmd[@]}"
      staged_locally_for_machine=true # Treat as "staged" if LOCAL_TARGET_BASE was primary
    fi
  done

  # If data for this machine was staged locally and there's a remote target, push it.
  if [[ "$staged_locally_for_machine" == true && -n "$REMOTE_TARGET_BASE" && -n "$LOCAL_TARGET_BASE" ]]; then
    # Ensure machine_backup_root here is the local staging path
    local local_stage_path="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
    local remote_dest_path="$REMOTE_TARGET_BASE/$current_user@$current_host" # Remote destination for this machine

    # It's possible target_machine_roots was set to remote if only remote was defined.
    # For hooks, we want the *final* resting place or the most complete local copy.
    # If we sync to remote from local, the remote becomes the more up-to-date for this staged data.
    # However, hooks might want to operate on the local staged data *before* a potentially slow remote sync,
    # or on the remote data *after*. This needs careful consideration for hook timing.
    # For now, target_machine_roots["$current_user@$current_host"] will be the LOCAL_TARGET_BASE one if it was used.
    # If hooks need to know about the remote push, that's a more complex state to pass.

    echo # for spacing
    echo "Backup Engine: Syncing staged data for $current_user@$current_host to remote..."
    echo "Path: $local_stage_path/ -> $remote_dest_path/"
    
    rsync_push_cmd=(rsync -az --delete) # Use -az, attributes and relative paths handled by first rsync
    [[ "$DRY_RUN" == "true" ]] && rsync_push_cmd+=(--dry-run)
    # Add $default_exclude if it should apply to the push as well
    # [[ -n "$default_exclude" ]] && rsync_push_cmd+=($default_exclude) 
    # Add $current_exclude if it should apply to the push from stage to remote
    # [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_push_cmd+=(--exclude-from="$current_exclude")
    
    rsync_push_cmd+=("$local_stage_path/" "$remote_dest_path/") # Note trailing slashes for content sync
    # echo "Command: ${rsync_push_cmd[*]}" # Potentially verbose
    "${rsync_push_cmd[@]}"
  fi

  backup_paths=() # Clear paths for the next machine
  current_exclude=""
}

# Read and process machine configuration files
for config_file in "$MACHINES_ENABLED_DIR"/*; do
  [[ -f "$config_file" ]] || continue # Skip if not a file

  # Reset machine-specific context
  current_user=""
  current_host=""
  backup_paths=() 

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}" # Remove comments
    line="${line#"${line%%[![:space:]]*}"}" # Remove leading whitespace
    line="${line%"${line##*[![:space:]]}"}"  # Remove trailing whitespace
    [[ -z "$line" ]] && continue # Skip empty or comment-only lines

    if [[ "$line" =~ ^\[(.+)@(.+)\]$ ]]; then
      # Before processing a new machine, flush any pending backups for the previous one
      if [[ -n "$current_user" && -n "$current_host" ]]; then
        flush_backup
        backup_paths=() # Ensure paths are reset after flush
      fi
      current_user="${BASH_REMATCH[1]}"
      current_host="${BASH_REMATCH[2]}"
      current_exclude="$EXCLUDES_DIR/$current_user@$current_host"
      echo # for spacing
      echo "Backup Engine: Processing machine: $current_user@$current_host"
      continue
    fi

    if [[ "$line" == src=* && -n "$current_user" && -n "$current_host" ]]; then
      raw_path="${line#src=}"
      # Expand ~ and variables, but be cautious with full globstar if not intended for all src
      # Using eval for this is powerful but requires trusted input in config files.
      expanded_path=$(eval echo "$raw_path")
      backup_paths+=($expanded_path)
    fi
  done < "$config_file"
  
  # After processing all lines in a config file, flush any pending backups for that machine
  if [[ -n "$current_user" && -n "$current_host" ]]; then
    flush_backup
  fi
done


# Post-backup hooks
if [[ -d "$HOOKS_DIR" ]]; then
  # Collect all unique target machine backup directories that were actually processed
  declare -a hook_target_dirs_final=()
  for path in "${target_machine_roots[@]}"; do
    # Check if the directory actually exists (i.e., was likely processed)
    # This is a simple check; more robust would be to track success.
    if [[ -d "$path" ]]; then 
      hook_target_dirs_final+=("$path")
    fi
  done
  
  # Ensure unique paths are passed to hooks (though target_machine_roots values should be unique machine roots)
  # This step might be redundant if target_machine_roots values are inherently unique.
  # Using process substitution with sort -u to get unique list.
  IFS=$'\n' read -d '' -ra unique_final_paths < <(printf "%s\n" "${hook_target_dirs_final[@]}" | sort -u && printf '\0')

  if [[ ${#unique_final_paths[@]} -gt 0 ]]; then
    for hook in "$HOOKS_DIR"/*; do
      if [[ -x "$hook" ]]; then
        echo # for spacing
        echo "Hooks: Running post-backup hook: $hook"
        # Pass each unique target directory as an argument to the hook
        # The hook script itself will iterate through "$@"
        "$hook" "${unique_final_paths[@]}"
      else
        echo # for spacing
        echo "Hooks: Skipping non-executable hook: $hook"
      fi
    done
  fi
else
  echo # for spacing
  echo "Hooks: No hooks directory found at $HOOKS_DIR, or directory is empty."
fi

echo # for spacing
echo "Backup Engine: All operations complete."
