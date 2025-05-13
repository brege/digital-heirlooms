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
  echo "Using specified configuration root: $CONFIG_ROOT"
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
      echo "Using user-defined configuration root from $DEFAULT_REPO_ENV_FILE: $CONFIG_ROOT"
    else
      # No CONFIG_DIR in repo's backup.env, so CONFIG_ROOT remains $CONFIG_ROOT_DEFAULT
      echo "Using default repository configuration root: $CONFIG_ROOT"
    fi
  else
    # No repo default backup.env, CONFIG_ROOT remains $CONFIG_ROOT_DEFAULT
    echo "Using default repository configuration root (backup.env not found in $CONFIG_ROOT_DEFAULT): $CONFIG_ROOT"
  fi
fi

# Now, CONFIG_ROOT is definitively set.
# Source the backup.env from this final CONFIG_ROOT.
ENV_FILE_TO_SOURCE="$CONFIG_ROOT/backup.env"
if [[ -f "$ENV_FILE_TO_SOURCE" ]]; then
  set -a  # Auto-export all variables from this env file
  source "$ENV_FILE_TO_SOURCE"
  set +a
else
  echo "[WARN] Environment file not found: $ENV_FILE_TO_SOURCE. Critical variables (DRY_RUN, target paths) may be unset." >&2
  # Set critical defaults if env file is missing to prevent unbound errors or misbehavior
  DRY_RUN="${DRY_RUN:-true}" # Default to true (safe) if no env file
  LOCAL_TARGET_BASE="${LOCAL_TARGET_BASE:-}"
  REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}"
  LOCAL_ARCHIVE_BASE="${LOCAL_ARCHIVE_BASE:-}"
  REMOTE_ARCHIVE_BASE="${REMOTE_ARCHIVE_BASE:-}"
fi

# Derived paths from the final CONFIG_ROOT
MACHINES_ENABLED_DIR="$CONFIG_ROOT/machines-enabled"
EXCLUDES_DIR="$CONFIG_ROOT/excludes"
HOOKS_DIR="$CONFIG_ROOT/hooks-enabled" # Using HOOKS_DIR as used later in script

echo "Backup Engine: Using machine configs from: $MACHINES_ENABLED_DIR"
echo "Backup Engine: Using excludes from: $EXCLUDES_DIR"
echo "Backup Engine: Using hooks from: $HOOKS_DIR"

DEFAULT_EXCLUDE="$EXCLUDES_DIR/default.exclude"
if [[ -f "$DEFAULT_EXCLUDE" ]]; then
  echo "Backup Engine: Applying global excludes from: $DEFAULT_EXCLUDE"
  default_exclude="--exclude-from=$DEFAULT_EXCLUDE"
else
  default_exclude=""
  echo "Backup Engine: No global exclude file found at $DEFAULT_EXCLUDE (this is okay)."
fi


REMOTE_TARGET_BASE="${REMOTE_TARGET_BASE:-}" # Ensure it's defined, default to empty if not from env
DRY_RUN="${DRY_RUN:-false}"                # Default from your original script, overridden by env if set
# LOCAL_TARGET_BASE should be defined by backup.env if used

# These flags were from your original script's global scope
direct_remote_rsync=false # This flag's original logic might need review based on new structure
staged_dirs=()            # This was used for the batch push from stage

current_user=""
current_host=""
current_exclude=""
backup_paths=()
declare -A target_machine_roots # Using this to pass to hooks

is_local_host() {
  [[ "$1" == "localhost" || "$1" == "$(hostname)" || "$1" == "$(hostname -f)" ]]
}

flush_backup() {
  [[ ${#backup_paths[@]} -eq 0 ]] && return

  local staged_locally_this_flush=false # Specific to this call of flush_backup

  for src_path in "${backup_paths[@]}"; do
    if [[ -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      # Scenario: Local staging then remote push
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir" # Store local stage path for hooks

      src_path_expanded=""
      if is_local_host "$current_host"; then use_ssh=false; src_path_expanded="$src_path"; else use_ssh=true; src_path_expanded="$current_user@$current_host:$src_path"; fi
      
      mkdir -p "$dest_dir"
      rsync_cmd=(rsync -avzR --delete $default_exclude)
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_cmd+=(--exclude-from="$current_exclude")
      $use_ssh && rsync_cmd+=(-e ssh)
      rsync_cmd+=("$src_path_expanded" "$dest_dir")

      echo # for spacing
      echo "Backup Engine: Rsyncing to local staging ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $dest_dir"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true

    elif [[ -z "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
      # Scenario: Direct remote rsync
      dest_dir="$REMOTE_TARGET_BASE/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir" # Store remote path for hooks
      
      src_path_expanded="$current_user@$current_host:$src_path"
      rsync_cmd=(rsync -avzR --delete $default_exclude)
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_cmd+=(--exclude-from="$current_exclude")
      rsync_cmd+=(-e ssh "$src_path_expanded" "${dest_dir%/}/") # Ensure target dir syntax for contents

      echo # for spacing
      echo "Backup Engine: Rsyncing directly to remote ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> ${dest_dir%/}/"
      "${rsync_cmd[@]}"
      # direct_remote_rsync=true; # This flag was part of the old batch logic

    else # Fallback: Only LOCAL_TARGET_BASE is set (or neither, which should be caught by pre-check)
      if [[ -z "$LOCAL_TARGET_BASE" ]]; then
          echo "[ERROR] flush_backup: LOCAL_TARGET_BASE is not set for local backup of $current_user@$current_host. Skipping path $src_path." >&2
          continue
      fi
      dest_dir="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
      target_machine_roots["$current_user@$current_host"]="$dest_dir" # Store local path for hooks

      src_path_expanded=""
      if is_local_host "$current_host"; then use_ssh=false; src_path_expanded="$src_path"; else use_ssh=true; src_path_expanded="$current_user@$current_host:$src_path"; fi

      mkdir -p "$dest_dir"
      rsync_cmd=(rsync -avzR --delete $default_exclude)
      [[ "$DRY_RUN" == "true" ]] && rsync_cmd+=(--dry-run)
      [[ -n "$current_exclude" && -f "$current_exclude" ]] && rsync_cmd+=(--exclude-from="$current_exclude")
      $use_ssh && rsync_cmd+=(-e ssh)
      rsync_cmd+=("$src_path_expanded" "$dest_dir")

      echo # for spacing
      echo "Backup Engine: Rsyncing to local destination ($current_user@$current_host):"
      echo "Path: $src_path_expanded -> $dest_dir"
      "${rsync_cmd[@]}"
      staged_locally_this_flush=true # Treat as "staged" if it's the primary local copy
    fi
  done

  # If data for this machine was staged locally AND there's a remote target, push it now.
  if [[ "$staged_locally_this_flush" == true && -n "$LOCAL_TARGET_BASE" && -n "$REMOTE_TARGET_BASE" ]]; then
    local local_stage_path="${LOCAL_TARGET_BASE%/}/$current_user@$current_host"
    local remote_dest_path="$REMOTE_TARGET_BASE/$current_user@$current_host"

    echo # for spacing
    echo "Backup Engine: Syncing staged data for $current_user@$current_host to remote..."
    echo "Path: $local_stage_path/ -> $remote_dest_path/"
    
    rsync_push_cmd=(rsync -az --delete $default_exclude) # Excludes can be passed here too if needed
    [[ "$DRY_RUN" == "true" ]] && rsync_push_cmd+=(--dry-run)
    rsync_push_cmd+=("$local_stage_path/" "$remote_dest_path/") 
    "${rsync_push_cmd[@]}"
  fi

  backup_paths=() # Clear paths for the next machine section in the same file or next file
  current_exclude=""
}

# Read and process machine configuration files
machine_processed_count=0
for config_file in "$MACHINES_ENABLED_DIR"/*; do
  if [[ ! -f "$config_file" ]]; then
    if [[ "$config_file" == "$MACHINES_ENABLED_DIR/*" ]]; then
        echo "[INFO] No machine configuration files found in $MACHINES_ENABLED_DIR."
    else
        echo "[WARN] Skipping non-file in MACHINES_ENABLED_DIR: $config_file"
    fi
    continue 
  fi
  
  # For each new file, reset machine context from previous file
  current_user="" 
  current_host=""
  backup_paths=() 

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"; [[ -z "$line" ]] && continue 

    if [[ "$line" =~ ^\[(.+)@(.+)\]$ ]]; then
      if [[ -n "$current_user" && -n "$current_host" ]]; then # Flush previous machine in this file
        flush_backup || echo "[WARN] A problem occurred in flush_backup for $current_user@$current_host (file: $config_file), continuing."
        backup_paths=() 
      fi
      current_user="${BASH_REMATCH[1]}"; current_host="${BASH_REMATCH[2]}"
      current_exclude="$EXCLUDES_DIR/$current_user@$current_host"
      echo; echo "Backup Engine: Processing machine: $current_user@$current_host from $config_file"
      machine_processed_count=$((machine_processed_count + 1))
      continue
    fi

    if [[ "$line" == src=* && -n "$current_user" && -n "$current_host" ]]; then
      raw_path="${line#src=}"
      # Using eval for path expansion; ensure config files are trusted.
      expanded_path=$(eval echo "$raw_path")
      backup_paths+=($expanded_path)
    fi
  done < "$config_file"
  
  # After processing all lines in the current config file, flush any pending backups for the last machine in it.
  if [[ -n "$current_user" && -n "$current_host" ]]; then
    flush_backup || echo "[WARN] A problem occurred in flush_backup for $current_user@$current_host (end of file: $config_file), continuing."
  fi
done

if [[ "$machine_processed_count" -eq 0 && "$MACHINES_ENABLED_DIR/*" != "$config_file" && "$config_file" != "" ]]; then
    # This condition might be tricky if MACHINES_ENABLED_DIR was empty and glob returned literal.
    # The earlier check for empty MACHINES_ENABLED_DIR handles that better.
    # If loop ran but machine_processed_count is 0, it means no [user@host] sections were found/parsed.
    echo "[INFO] No valid [user@host] sections found in processed configuration files."
fi


# Post-backup hooks
# Check if any machines were processed and resulted in target roots
if [[ ${#target_machine_roots[@]} -eq 0 ]]; then
    if [[ "$machine_processed_count" -gt 0 ]]; then
        echo "[INFO] Machines were processed, but no valid backup target directories were recorded. Skipping hooks."
    else
        echo "[INFO] No machines processed. Skipping hooks."
    fi
else
    if [[ -d "$HOOKS_DIR" ]]; then
      declare -a hook_target_dirs_final=()
      for path_val in "${target_machine_roots[@]}"; do if [[ -d "$path_val" ]]; then hook_target_dirs_final+=("$path_val"); fi; done
      IFS=$'\n' read -d '' -ra unique_final_paths < <(printf "%s\n" "${hook_target_dirs_final[@]}" | sort -u && printf '\0')

      if [[ ${#unique_final_paths[@]} -gt 0 ]]; then
        for hook in "$HOOKS_DIR"/*; do 
          if [[ -f "$hook" && -x "$hook" ]]; then
            echo; echo "Hooks: Running post-backup hook: $hook on targets: ${unique_final_paths[*]}"
            "$hook" "${unique_final_paths[@]}"
          elif [[ -f "$hook" ]]; then 
            echo; echo "Hooks: Skipping non-executable file hook: $hook"
          else 
            echo; echo "Hooks: Skipping non-file or non-executable item in hooks directory: $hook"
          fi
        done
      else 
        echo; echo "Hooks: No valid target directories available for hooks after processing."
      fi
    else 
      echo; echo "Hooks: No hooks directory found at $HOOKS_DIR, or directory is empty."
    fi
fi
echo; echo "Backup Engine: All operations complete."
