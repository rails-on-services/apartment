#!/usr/bin/env bash
# bin/dev/_gum.sh — Shared UX helpers for development scripts
#
# Provides logging, confirmation, and progress functions with optional
# charmbracelet/gum integration. Falls back to plain terminal output
# when gum is not installed.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/_gum.sh"
#
# Install gum for enhanced UX:
#   brew install gum

# ---------------------------------------------------------------------------
# Gum detection
# ---------------------------------------------------------------------------
if [ -z "${GUM_AVAILABLE+x}" ]; then
  GUM_AVAILABLE=false
  command -v gum &>/dev/null && GUM_AVAILABLE=true
fi

# Consistent header color across all gum components (ANSI 256: dodger blue).
GUM_HEADER_COLOR=212

# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  CLR_RED='\033[0;31m'
  CLR_GREEN='\033[0;32m'
  CLR_YELLOW='\033[1;33m'
  CLR_BLUE='\033[0;34m'
  CLR_CYAN='\033[0;36m'
  CLR_RESET='\033[0m'
else
  CLR_RED=''
  CLR_GREEN=''
  CLR_YELLOW=''
  CLR_BLUE=''
  CLR_CYAN=''
  CLR_RESET=''
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info() {
  if $GUM_AVAILABLE; then
    gum log --level info "$@"
  else
    echo "ℹ️  $*" >&2
  fi
}

log_warn() {
  if $GUM_AVAILABLE; then
    gum log --level warn "$@"
  else
    echo "⚠️  $*" >&2
  fi
}

log_error() {
  if $GUM_AVAILABLE; then
    gum log --level error "$@"
  else
    echo "❌ $*" >&2
  fi
}

log_success() {
  if $GUM_AVAILABLE; then
    gum log --level info "✓ $*"
  else
    echo "✅ $*" >&2
  fi
}

# ---------------------------------------------------------------------------
# Visual structure
# ---------------------------------------------------------------------------
header() {
  if $GUM_AVAILABLE; then
    gum style --bold --foreground "$GUM_HEADER_COLOR" --border double --border-foreground "$GUM_HEADER_COLOR" --padding "0 2" "$*"
  else
    echo ""
    echo "══ $* ══"
    echo ""
  fi
}

section() {
  if $GUM_AVAILABLE; then
    gum style --faint "━━━ $*"
  else
    echo "━━━ $*"
  fi
}

# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------
confirm() {
  if $GUM_AVAILABLE; then
    gum confirm "$1"
  else
    read -r -p "$1 [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]]
  fi
}

choose() {
  local hdr="$1"; shift
  local default_val=""
  if [ "${1:-}" = "--default" ]; then
    default_val="$2"; shift 2
  fi
  if $GUM_AVAILABLE; then
    if [ -n "$default_val" ]; then
      gum choose --header "$hdr" --header.foreground "$GUM_HEADER_COLOR" --selected "$default_val" "$@"
    else
      gum choose --header "$hdr" --header.foreground "$GUM_HEADER_COLOR" "$@"
    fi
  else
    local i=1
    echo "$hdr" >&2
    for item in "$@"; do
      if [ "$item" = "$default_val" ]; then
        echo "  $i) $item (default)" >&2
      else
        echo "  $i) $item" >&2
      fi
      i=$((i + 1))
    done
    if [ -n "$default_val" ]; then
      read -r -p "Choice [1-$#, Enter=default]: " REPLY
    else
      read -r -p "Choice [1-$#]: " REPLY
    fi
    if [ -z "$REPLY" ] && [ -n "$default_val" ]; then
      echo "$default_val"
      return 0
    fi
    local j=1
    for item in "$@"; do
      if [ "$j" = "$REPLY" ]; then
        echo "$item"
        return 0
      fi
      j=$((j + 1))
    done
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------
spin() {
  local title="$1"; shift
  if $GUM_AVAILABLE; then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    echo "$title"
    "$@"
  fi
}
