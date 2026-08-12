#!/usr/bin/env bash
# daily-update.sh — Safe daily update for hermes-agent
# Designed to run unattended (launchd). Preserves local commits and untracked files.
# Logs to ~/.hermes/logs/daily-update.log

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
REPO_DIR="/Users/bensopenclaw/.hermes/hermes-agent"
LOG_DIR="/Users/bensopenclaw/.hermes/logs"
LOG_FILE="$LOG_DIR/daily-update.log"
GATEWAY_LABEL="ai.hermes.gateway"
VENV_PIP="$REPO_DIR/venv/bin/pip"
VENV_PYTHON="$REPO_DIR/venv/bin/python"
DROID_BIN="/opt/homebrew/bin/droid"
REMOTE="origin"
BRANCH="main"
MAX_LOG_LINES=2000  # rotate log if it exceeds this
ENV_FILE="/Users/bensopenclaw/.hermes/.env"
ESCALATION_LOCK="$LOG_DIR/daily-update-droid.lock"
ESCALATION_LOG="$LOG_DIR/daily-update-droid.log"
# A Droid escalation that has been running longer than this is assumed dead
# (the background subshell crashed without cleaning up the lock). The lock is
# removed so the next run can escalate again instead of being stuck forever.
ESCALATION_LOCK_MAX_AGE=$((2 * 3600))  # 2 hours

# Load Discord webhook URL from .env.
# Keep Hermes update notifications separate from Droid's working/poller webhooks.
DISCORD_WEBHOOK=""
if [[ -f "$ENV_FILE" ]]; then
    DISCORD_WEBHOOK=$(grep '^HERMES_DAILY_UPDATE_WEBHOOK=' "$ENV_FILE" | cut -d= -f2- || true)
    if [[ -z "$DISCORD_WEBHOOK" ]]; then
        # Back-compat for older installs that had a generic update webhook name.
        DISCORD_WEBHOOK=$(grep '^DISCORD_DAILY_UPDATE_WEBHOOK=' "$ENV_FILE" | cut -d= -f2- || true)
    fi
fi

# ── Helpers ─────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
    log "FATAL: $*"
    escalate_to_droid "fatal: $*"
    exit 1
}

rotate_log() {
    if [[ -f "$LOG_FILE" ]] && (( $(wc -l < "$LOG_FILE") > MAX_LOG_LINES )); then
        tail -n "$((MAX_LOG_LINES / 2))" "$LOG_FILE" > "$LOG_FILE.tmp"
        mv "$LOG_FILE.tmp" "$LOG_FILE"
        log "(log rotated)"
    fi
}

send_discord_update() {
    # Send a Discord notification about a successful update.
    # Args: $1=old_head $2=remote_head $3=commit_count
    local old="$1" new="$2" count="$3"

    if [[ -z "$DISCORD_WEBHOOK" ]]; then
        log "Discord webhook not configured — skipping notification"
        return 0
    fi

    # Get version from pyproject.toml
    local version
    version=$(grep '^version' "$REPO_DIR/pyproject.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")

    # Get latest git tag if any
    local latest_tag
    latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

    # Generate patch notes via AI (gemini-2.5-flash) with categorized fallback
    local patch_notes
    patch_notes=$(python3 "$REPO_DIR/scripts/gen-patch-notes.py" "$REPO_DIR" "$old" "$new" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('summary',''))" 2>/dev/null || echo "")

    # Fallback to raw git log if AI notes failed
    if [[ -z "$patch_notes" ]]; then
        log "Patch notes generation failed — using raw commit list"
        patch_notes=$(git log --oneline "$old..$new" --no-merges 2>/dev/null | head -15 || echo "(no details)")
    fi

    local title="Hermes Updated — v${version}"
    [[ -n "$latest_tag" ]] && title="Hermes Updated — v${version} (${latest_tag})"

    local now_date
    now_date=$(date '+%Y-%m-%d %H:%M')

    # Build JSON payload safely via python3 to handle all escaping
    local payload
    payload=$(TITLE="$title" COUNT="$count" PATCH_NOTES="$patch_notes" \
              OLD_SHA="$old" NEW_SHA="$new" NOW_DATE="$now_date" python3 - <<'PYNOTIFY'
import json, os
title = os.environ["TITLE"]
desc = "**" + os.environ["COUNT"] + " new commit(s)** pulled and deployed.\n\n" + os.environ["PATCH_NOTES"]
footer = os.environ["OLD_SHA"][:7] + " \u2192 " + os.environ["NEW_SHA"][:7] + " \u00b7 " + os.environ["NOW_DATE"]
print(json.dumps({
    "embeds": [{
        "title": title,
        "description": desc,
        "color": 5025616,
        "footer": {"text": footer}
    }]
}))
PYNOTIFY
    )

    if curl -s -o /dev/null -w '%{http_code}' \
         -H "Content-Type: application/json" \
         -d "$payload" \
         "$DISCORD_WEBHOOK" | grep -q '^2'; then
        log "Discord notification sent"
    else
        log "WARNING: Discord notification failed (non-fatal)"
    fi
}


send_discord_notice() {
    # Send a generic Discord notification.
    # Args: $1=title $2=description $3=color
    local title="$1" description="$2" color="${3:-16753920}"

    if [[ -z "$DISCORD_WEBHOOK" ]]; then
        log "Discord webhook not configured — skipping notification: $title"
        return 0
    fi

    local payload
    payload=$(TITLE="$title" DESCRIPTION="$description" COLOR="$color" python3 - <<'PY'
import json
import os

print(json.dumps({
    "embeds": [{
        "title": os.environ["TITLE"],
        "description": os.environ["DESCRIPTION"],
        "color": int(os.environ["COLOR"]),
    }]
}))
PY
)

    if curl -s -o /dev/null -w '%{http_code}' \
         -H "Content-Type: application/json" \
         -d "$payload" \
         "$DISCORD_WEBHOOK" | grep -q '^2'; then
        log "Discord notice sent: $title"
    else
        log "WARNING: Discord notice failed (non-fatal): $title"
    fi
}

_lock_is_stale() {
    # Return 0 (true) when the escalation lock directory is older than
    # ESCALATION_LOCK_MAX_AGE or the PID recorded inside is no longer alive.
    # This lets escalate_to_droid recover from a crashed Droid process that
    # left an orphaned lock behind — the original bug that permanently blocked
    # every subsequent daily update.
    local lock_dir="$1"

    # Age check: compare mtime to now.
    local lock_mtime now age
    lock_mtime=$(stat -f %m "$lock_dir" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - lock_mtime))
    if (( age > ESCALATION_LOCK_MAX_AGE )); then
        log "Escalation lock is stale (age=${age}s > ${ESCALATION_LOCK_MAX_AGE}s). Will reclaim."
        return 0
    fi

    # PID-liveness check: if a pid file exists inside the lock and that PID
    # is dead, the lock is orphaned regardless of age.
    local pid_file="$lock_dir/pid"
    if [[ -f "$pid_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            log "Escalation lock held by PID $lock_pid, which is no longer running. Will reclaim."
            return 0
        fi
    fi

    return 1
}

escalate_to_droid() {
    # Start a headless Droid session for cases the deterministic updater should
    # not improvise through: dirty checkout, conflicts, failed tests, failed
    # restart, or other unexpected update errors.
    local reason="$1"

    if [[ "${HERMES_UPDATE_DROID_ESCALATION:-}" == "1" ]]; then
        log "Droid escalation suppressed inside an existing escalation."
        return 0
    fi
    if [[ ! -x "$DROID_BIN" ]]; then
        log "Droid CLI not found at $DROID_BIN; cannot escalate."
        send_discord_notice "Hermes update needs attention" "Reason: \`${reason}\`\nDroid CLI was not found at \`${DROID_BIN}\`. Check \`${LOG_FILE}\`." 16753920
        return 0
    fi

    # If a lock already exists, check whether it's stale before giving up.
    # A previous Droid escalation that crashed (or was killed) without
    # cleaning up its lock would permanently block every future escalation.
    if [[ -d "$ESCALATION_LOCK" ]]; then
        if _lock_is_stale "$ESCALATION_LOCK"; then
            log "Removing stale escalation lock: $ESCALATION_LOCK"
            rm -rf "$ESCALATION_LOCK"
        else
            log "Droid escalation already running or lock exists: $ESCALATION_LOCK"
            send_discord_notice "Hermes update escalation already active" "Reason: \`${reason}\`\nLock exists at \`${ESCALATION_LOCK}\`. Check \`${ESCALATION_LOG}\`." 16753920
            return 0
        fi
    fi

    if ! mkdir "$ESCALATION_LOCK" 2>/dev/null; then
        log "Could not create escalation lock: $ESCALATION_LOCK"
        send_discord_notice "Hermes update escalation failed" "Reason: \`${reason}\`\nCould not create lock at \`${ESCALATION_LOCK}\`." 16753920
        return 0
    fi

    local prompt_file="$LOG_DIR/daily-update-droid-prompt-$(date '+%Y%m%d-%H%M%S').md"
    local status_snapshot
    status_snapshot=$(git -C "$REPO_DIR" status --short 2>&1 || true)
    local branch_snapshot
    branch_snapshot=$(git -C "$REPO_DIR" status -sb 2>&1 || true)
    local recent_log
    recent_log=$(tail -120 "$LOG_FILE" 2>/dev/null || true)

    cat > "$prompt_file" <<PROMPT
You are running as a headless Droid escalation for Ben's local Hermes updater.

Goal: safely get /Users/bensopenclaw/.hermes/hermes-agent updated and the Hermes gateway healthy.

Trigger reason:
${reason}

Required safety rules:
- Do not delete, overwrite, move, or clean untracked files.
- Do not use git push.
- Do not use sudo.
- Do not discard local changes. If local changes block the update, preserve them on a clearly named branch or commit only after reviewing the diff for secrets.
- Prefer deterministic commands. Use AI judgment only for conflicts, dirty state, tests, and health diagnosis.
- If you cannot safely complete the update, leave the repo untouched beyond any explicitly safe local branch/commit you made and report exactly what Ben needs to do.

Expected flow:
1. Inspect git status, remotes, branch, and recent updater logs.
2. If dirty, identify whether changes are intentional local patches. Preserve them safely before updating.
3. Fetch ${REMOTE}/${BRANCH}, update/rebase only if safe, install dependencies if needed, then run targeted validators.
4. Restart \`${GATEWAY_LABEL}\` using launchctl only after validators pass.
5. Verify the gateway process is running and Discord connected in logs.
6. Write a concise result summary to ${ESCALATION_LOG}. If a Discord webhook is available in ${ENV_FILE}, notify Ben.

Current branch/status snapshot:
\`\`\`
${branch_snapshot}
${status_snapshot}
\`\`\`

Recent updater log:
\`\`\`
${recent_log}
\`\`\`
PROMPT

    log "Starting headless Droid escalation: $reason"
    send_discord_notice "Hermes update escalated to Droid" "Reason: \`${reason}\`\nDroid is running headless. Log: \`${ESCALATION_LOG}\`." 16753920

    (
        export HERMES_UPDATE_DROID_ESCALATION=1
        {
            echo "========== Droid escalation $(date '+%Y-%m-%d %H:%M:%S') =========="
            echo "Reason: $reason"
            "$DROID_BIN" exec --cwd "$REPO_DIR" --auto medium --model gpt-5.5 -f "$prompt_file"
            rc=$?
            echo "Droid exit code: $rc"
            rmdir "$ESCALATION_LOCK" 2>/dev/null || true
            exit "$rc"
        } >> "$ESCALATION_LOG" 2>&1
    ) &

    # Write the background PID into the lock so future runs can detect a
    # dead escalation process via kill -0 and reclaim the lock immediately
    # rather than waiting for the age threshold.
    echo "$!" > "$ESCALATION_LOCK/pid"

    log "Headless Droid escalation started in background (pid=$!, prompt=$prompt_file)"
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
rotate_log

log "========== Daily update starting =========="

cd "$REPO_DIR" || die "Cannot cd to $REPO_DIR"

# Confirm we're on the expected branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    die "Not on '$BRANCH' (on '$CURRENT_BRANCH'). Skipping update to avoid surprises."
fi

# Record pre-update state
OLD_HEAD=$(git rev-parse HEAD)
log "Current HEAD: $OLD_HEAD ($(git log --oneline -1))"

# ── Stash local changes (if any) ────────────────────────────────────────────
# Auto-stash (including untracked files) so the rebase can proceed cleanly.
# This mirrors the behavior of `hermes update`.
STASH_CREATED=false
if [[ -n "$(git status --porcelain)" ]]; then
    STASH_MSG="hermes-update-autostash-$(date '+%Y%m%d-%H%M%S')"
    log "Local changes detected — stashing before update..."
    git status --short 2>&1 | while read -r line; do log "  status: $line"; done
    git stash push -m "$STASH_MSG" --include-untracked 2>&1 | while read -r line; do log "  stash: $line"; done
    STASH_CREATED=true
    log "Stashed local changes as '$STASH_MSG'"
else
    log "Working tree clean (no stash needed)"
fi

# ── Fetch ───────────────────────────────────────────────────────────────────
log "Fetching $REMOTE/$BRANCH..."
if ! git fetch "$REMOTE" "$BRANCH" 2>&1 | while read -r line; do log "  fetch: $line"; done; then
    log "WARNING: fetch failed (network issue?). Restoring stash if needed."
    if $STASH_CREATED; then git stash pop 2>/dev/null || true; fi
    die "Fetch failed. Will retry tomorrow."
fi

# ── Check if update is needed ───────────────────────────────────────────────
REMOTE_HEAD=$(git rev-parse "$REMOTE/$BRANCH")
if [[ "$OLD_HEAD" == "$REMOTE_HEAD" ]] || git merge-base --is-ancestor "$REMOTE_HEAD" HEAD 2>/dev/null; then
    log "Already up to date (remote HEAD: ${REMOTE_HEAD:0:12}). Nothing to do."
    if $STASH_CREATED; then
        git stash pop 2>&1 | while read -r line; do log "  stash-pop: $line"; done
    fi
    log "========== Update complete (no-op) =========="
    exit 0
fi

log "Remote has new commits: ${OLD_HEAD:0:12} -> ${REMOTE_HEAD:0:12}"

# Count local commits ahead of remote (these will be rebased on top)
LOCAL_AHEAD=$(git rev-list "$REMOTE/$BRANCH..HEAD" --count 2>/dev/null || echo 0)
if (( LOCAL_AHEAD > 0 )); then
    log "Local has $LOCAL_AHEAD commit(s) ahead of $REMOTE/$BRANCH — will rebase them on top"
    git log --oneline "$REMOTE/$BRANCH..HEAD" 2>&1 | while read -r line; do log "  local: $line"; done
fi

# ── Rebase ──────────────────────────────────────────────────────────────────
log "Rebasing onto $REMOTE/$BRANCH..."
if git rebase "$REMOTE/$BRANCH" 2>&1 | while read -r line; do log "  rebase: $line"; done; then
    NEW_HEAD=$(git rev-parse HEAD)
    log "Rebase succeeded. New HEAD: ${NEW_HEAD:0:12} ($(git log --oneline -1))"
else
    log "ERROR: Rebase conflicted! Aborting rebase and restoring previous state."
    git rebase --abort 2>&1 | while read -r line; do log "  abort: $line"; done
    if $STASH_CREATED; then
        git stash pop 2>/dev/null || true
    fi
    die "Rebase conflict — manual intervention required. Local state preserved."
fi

# ── Restore stash ───────────────────────────────────────────────────────────
if $STASH_CREATED; then
    if git stash pop 2>&1 | while read -r line; do log "  stash-pop: $line"; done; then
        log "Stash restored successfully"
    else
        log "WARNING: Stash pop had conflicts. Stash preserved in stash list."
        git checkout -- . 2>/dev/null || true
    fi
fi

# ── Reinstall dependencies ──────────────────────────────────────────────────
log "Reinstalling Python dependencies..."
if "$VENV_PIP" install -q -e "$REPO_DIR" 2>&1 | tail -5 | while read -r line; do log "  pip: $line"; done; then
    log "Dependencies updated"
else
    log "WARNING: pip install had issues (non-fatal, gateway may still work)"
fi

# Rebuild TUI if node_modules exists
if [[ -d "$REPO_DIR/ui-tui/node_modules" ]]; then
    log "Rebuilding TUI..."
    if (cd "$REPO_DIR/ui-tui" && npm run build 2>&1 | tail -3 | while read -r line; do log "  tui: $line"; done); then
        log "TUI rebuilt"
    else
        log "WARNING: TUI build failed (non-fatal)"
    fi
fi

# ── Lightweight validation ─────────────────────────────────────────────────
log "Running lightweight Hermes validators..."
if "$VENV_PYTHON" -m py_compile \
    "$REPO_DIR/gateway/run.py" \
    "$REPO_DIR/cron/jobs.py" \
    "$REPO_DIR/cron/scheduler.py" \
    "$REPO_DIR/tools/cronjob_tools.py" 2>&1 | while read -r line; do log "  py_compile: $line"; done; then
    log "Python compile validators passed"
else
    die "Python compile validators failed after update"
fi

if [[ -f "$REPO_DIR/tests/tools/test_cronjob_tools.py" ]]; then
    if "$VENV_PYTHON" -m pytest "$REPO_DIR/tests/tools/test_cronjob_tools.py" -q 2>&1 | tail -20 | while read -r line; do log "  pytest: $line"; done; then
        log "Targeted cronjob tests passed"
    else
        die "Targeted cronjob tests failed after update"
    fi
fi

# ── Restart gateway ─────────────────────────────────────────────────────────
# The gateway plist sets KeepAlive.SuccessfulExit=false, so `launchctl stop`
# triggers a clean SIGTERM -> exit 0 and launchd will NOT respawn it. Use
# `kickstart -k` instead — it kills the current instance and starts a fresh one
# regardless of how the previous one exited.
log "Restarting Hermes gateway ($GATEWAY_LABEL)..."
GUI_DOMAIN="gui/$(id -u)"
if launchctl kickstart -k "$GUI_DOMAIN/$GATEWAY_LABEL" 2>&1 | while read -r line; do log "  kickstart: $line"; done; then
    sleep 3
    GW_PID=$(launchctl list | awk -v lbl="$GATEWAY_LABEL" '$3==lbl {print $1}')
    if [[ -n "$GW_PID" && "$GW_PID" != "-" ]]; then
        log "Gateway restarted (PID: $GW_PID)"
    else
        die "Gateway did not come back up. Check 'launchctl list | grep hermes'."
    fi
else
    die "launchctl kickstart failed — gateway may be stopped"
fi

# ── Summary & Notification ───────────────────────────────────────────────────
COMMITS_PULLED=$(git rev-list "$OLD_HEAD..$REMOTE_HEAD" --count 2>/dev/null || echo "?")
log "SUCCESS: Updated hermes-agent ($COMMITS_PULLED new commits). Gateway restarted."

# Notify Discord about the successful update
send_discord_update "$OLD_HEAD" "$REMOTE_HEAD" "$COMMITS_PULLED"

log "========== Update complete =========="
