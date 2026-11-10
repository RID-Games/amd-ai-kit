#!/usr/bin/env bash
# amd-ai-kit installer — renders llama-swap configs + systemd user units from
# templates/ using values in ./.env. Pure bash, no gettext/envsubst needed.
#
# Usage:
#   ./install.sh [options] [profile ...]
#
# Profiles: 9060xt  v620  cpu  all        (default: all)
# Options:
#   --enable     also: systemctl --user enable --now <unit>
#   --no-units   render configs only, skip systemd units
#   --dry-run    render to ./rendered/ instead of the real destinations
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KIT_DIR"

# --- config ------------------------------------------------------------------
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "No .env found — created ./.env from .env.example."
  echo "Edit it (paths, ports, GPU UUIDs), then re-run ./install.sh"
  exit 1
fi
set -a; . ./.env; set +a

# Secrets store: created 0600 on first run. NEVER rendered into configs or
# units — helper scripts source it instead.
SECRETS_FILE="${SECRETS_FILE:-$HOME/.config/amd-ai-kit/secrets.env}"
if [[ ! -f "$SECRETS_FILE" ]]; then
  install -d "$(dirname "$SECRETS_FILE")"
  install -m 600 secrets.env.example "$SECRETS_FILE"
  echo "Created secrets store: $SECRETS_FILE (mode 600)."
  echo "Put HF_TOKEN etc. THERE — never in .env, configs, or units."
fi

# Whitelist of template variables. ${PORT} is deliberately NOT here: it is
# llama-swap's own placeholder and must survive rendering.
VARS=(
  LLAMA_SWAP_BIN LLAMA_SERVER MODEL_DIR CONFIG_DIR WORKDIR REQUIRES_MOUNT
  THEROCK_LIB GPU_CHAT_UUID GPU_LLM_UUID
  PORT_CHAT PORT_LLM PORT_CPU
  STARTPORT_CHAT STARTPORT_LLM STARTPORT_CPU
  GEMMA_GGUF GEMMA_MMPROJ MINICPM_GGUF QWEN8B_GGUF QWEN27B_GGUF
  COLI_BIN GLM_MODEL_DIR VK_SHADERS_DIR VK_DRIVER_FILES
  GLM53_EXPERT_GB GLM_MEMORY_MAX
)

# --- args ----------------------------------------------------------------------
ENABLE=0; NO_UNITS=0; DRY=0; PROFILES=()
for arg in "$@"; do
  case "$arg" in
    --enable)   ENABLE=1 ;;
    --no-units) NO_UNITS=1 ;;
    --dry-run)  DRY=1 ;;
    all)        PROFILES=(9060xt v620 cpu) ;;
    9060xt|v620|cpu) PROFILES+=("$arg") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ ${#PROFILES[@]} -eq 0 ]] && PROFILES=(9060xt v620 cpu)

# --- sanity checks ---------------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ -x "$LLAMA_SWAP_BIN" ]] || fail "LLAMA_SWAP_BIN not executable: $LLAMA_SWAP_BIN
  Get a static build: https://github.com/mostlygeek/llama-swap/releases"
[[ -x "$LLAMA_SERVER" ]]   || fail "LLAMA_SERVER not executable: $LLAMA_SERVER
  Build it first (README: 'Building llama.cpp for AMD')."
[[ -d "$MODEL_DIR" ]]      || fail "MODEL_DIR does not exist: $MODEL_DIR"
command -v systemctl >/dev/null || [[ $NO_UNITS -eq 1 ]] || fail "systemctl not found; use --no-units"

# --- renderer ----------------------------------------------------------------------
# Replaces ${NAME} for whitelisted names only; everything else (e.g. ${PORT})
# passes through untouched. Unset whitelist vars render as empty and are warned.
render() {
  local file="$1" line name
  while IFS= read -r line || [[ -n "$line" ]]; do
    for name in "${VARS[@]}"; do
      if [[ "$line" == *'${'"$name"'}'* ]]; then
        [[ -n "${!name+x}" ]] || echo "WARNING: $name not set in .env (rendering empty)" >&2
        line="${line//\$\{$name\}/${!name-}}"
      fi
    done
    printf '%s\n' "$line"
  done < "$file"
}

# --- render --------------------------------------------------------------------------
OUT_CONFIG="$CONFIG_DIR"
OUT_UNITS="$HOME/.config/systemd/user"
if [[ $DRY -eq 1 ]]; then
  OUT_CONFIG="$KIT_DIR/rendered"
  OUT_UNITS="$KIT_DIR/rendered"
  rm -rf "$KIT_DIR/rendered"
fi
mkdir -p "$OUT_CONFIG"
[[ $NO_UNITS -eq 1 || $DRY -eq 1 ]] || mkdir -p "$OUT_UNITS"

for p in "${PROFILES[@]}"; do
  render "templates/llama-swap-$p.yaml" > "$OUT_CONFIG/llama-swap-$p.yaml"
  echo "config → $OUT_CONFIG/llama-swap-$p.yaml"
  if [[ $NO_UNITS -eq 0 ]]; then
    render "templates/llama-swap-$p.service" > "$OUT_UNITS/llama-swap-$p.service"
    echo "unit   → $OUT_UNITS/llama-swap-$p.service"
  fi
done

if [[ $DRY -eq 0 && $NO_UNITS -eq 0 ]]; then
  systemctl --user daemon-reload
  echo "systemd user daemon reloaded."
  if [[ $ENABLE -eq 1 ]]; then
    for p in "${PROFILES[@]}"; do
      systemctl --user enable --now "llama-swap-$p.service"
      echo "enabled+started: llama-swap-$p.service"
    done
  fi
fi

# --- next steps ----------------------------------------------------------------------
echo
echo "Verify (after starting a unit):"
for p in "${PROFILES[@]}"; do
  case $p in
    9060xt) port="$PORT_CHAT" ;;
    v620)   port="$PORT_LLM" ;;
    cpu)    port="$PORT_CPU" ;;
  esac
  echo "  systemctl --user start llama-swap-$p    # then:"
  echo "  curl -s http://127.0.0.1:$port/v1/models | head"
done
echo
echo "First load of a big model is slow (cold page cache). See the load-time"
echo "table in llama-swap-v620.yaml before lowering healthCheckTimeout."
