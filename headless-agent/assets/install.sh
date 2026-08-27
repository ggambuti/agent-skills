#!/bin/sh
# install.sh — idempotent installer for the headless agent loop.
# RUN THIS YOURSELF (the user): persistent-service installation and
# credential handling are user-approved by design, and a setup agent may
# be blocked from launchctl/systemd or from ~/Library/LaunchAgents.
# Re-running it (e.g. after fixing auth) is the normal retry path.
#
# Usage: ./install.sh /path/to/repo [branch]

set -eu
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:?usage: install.sh /path/to/repo [branch] [model]}"
BRANCH="${2:-agent-work}"
MODEL="${3:-sonnet}"   # orchestrator model; subagents are tiered by prompt

# ---------------------------------------------------------------------
# STEP 1 — AUTH GATE (always first; refuse to install a loop that
# cannot authenticate).
# The probe runs in a launchd/systemd-like MINIMAL environment: a probe
# in your interactive shell can pass spuriously (your session has
# working credentials) while the service then fails on its first cycle.
# Note: an expired OAuth token can look fine interactively while
# `claude -p` fails with "OAuth session expired and could not be
# refreshed".
# ---------------------------------------------------------------------
echo "[install] probing headless auth in a minimal environment..."
if env -i HOME="$HOME" PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin \
     sh -c ". \"$KIT_DIR/env.sh\" 2>/dev/null; claude -p \"Reply with exactly: AUTH-OK\" --model haiku" \
     2>"$KIT_DIR/auth-probe.err" | grep -q "AUTH-OK"; then
  echo "[install] auth OK"
else
  cat <<MSG
[install] AUTH FAILED — refusing to install a loop that cannot
authenticate (it would poll forever looking like an outage).
Probe stderr: $KIT_DIR/auth-probe.err

Fix — you must do this yourself; agents must not see or handle tokens:
  1. Run:   claude setup-token
     (opens a browser OAuth flow with your Claude subscription account;
      prints a long-lived sk-ant-oat01-... token)
  2. Store it in a private env file the loop sources at startup
     (the macOS keychain is NOT a reliable credential source under
      launchd — use this file route):
       printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' 'sk-ant-oat01-PASTE-HERE' > "$KIT_DIR/env.sh"
       chmod 600 "$KIT_DIR/env.sh"
  3. Re-run this installer. Success looks like: "[install] auth OK".
MSG
  exit 1
fi

# ---------------------------------------------------------------------
# STEP 2 — install the platform service (idempotent).
# ---------------------------------------------------------------------
case "$(uname)" in
  Darwin)
    LABEL="com.$(id -un).claude-agent"
    PLIST_SRC="$KIT_DIR/com.USER.claude-agent.plist"
    PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    sed -e "s@__LABEL__@$LABEL@g" \
        -e "s@__KIT_DIR__@$KIT_DIR@g" \
        -e "s@__REPO__@$REPO@g" \
        -e "s@__BRANCH__@$BRANCH@g" \
        -e "s@__MODEL__@$MODEL@g" \
        -e "s@__HOME__@$HOME@g" \
        "$PLIST_SRC" > "$PLIST_DST"
    plutil -lint "$PLIST_DST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
    echo "[install] launchd service $LABEL installed and started (model: $MODEL)."
    echo "[install] heartbeat log (stdout): $KIT_DIR/launchd.out.log"
    echo "[install] error log   (stderr): $KIT_DIR/launchd.err.log"
    echo "[install] REMINDER: caffeinate holds sleep on AC power only —"
    echo "[install] leave the machine plugged in (lid open, or a desktop)."
    ;;
  *)
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    sed -e "s@__KIT_DIR__@$KIT_DIR@g" \
        -e "s@__REPO__@$REPO@g" \
        -e "s@__BRANCH__@$BRANCH@g" \
        -e "s@__MODEL__@$MODEL@g" \
        -e "s@__HOME__@$HOME@g" \
        "$KIT_DIR/claude-agent.service" > "$UNIT_DIR/claude-agent.service"
    systemctl --user daemon-reload
    systemctl --user enable --now claude-agent
    loginctl enable-linger "$(id -un)" || true
    echo "[install] systemd service claude-agent installed and started (model: $MODEL)."
    echo "[install] watch: journalctl --user -u claude-agent -f"
    ;;
esac
echo "[install] operator card will appear at $REPO/HANDOVER.md on first launch."
