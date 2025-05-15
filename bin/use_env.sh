#!/bin/bash

set -euo pipefail

# Optional: allow full path or just basename
ENV_ARG="${1:-}"

if [[ -z "$ENV_ARG" ]]; then
  echo "Usage: $0 <env-file-name or path>"
  echo "Example: $0 user@host_.env"
  echo "         $0 ./config/env/user@host_.env"
  exit 1
fi

# Determine full path
if [[ "$ENV_ARG" = /* ]]; then
  # Absolute path
  ENV_PATH="$ENV_ARG"
elif [[ "$ENV_ARG" == */* ]]; then
  # Relative path already includes directories
  ENV_PATH="$(realpath "$ENV_ARG")"
else
  # Just a filename — assume it lives in ../config/env
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ENV_PATH="$(realpath "$SCRIPT_DIR/../config/env/$ENV_ARG")"
fi

# Target symlink location
TARGET_LINK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/backup.env"

if [[ ! -f "$ENV_PATH" ]]; then
  echo "ERROR: No such env file: $ENV_PATH" >&2
  exit 1
fi

ln -sf "$ENV_PATH" "$TARGET_LINK"
echo "Linked $TARGET_LINK -> $ENV_PATH"
