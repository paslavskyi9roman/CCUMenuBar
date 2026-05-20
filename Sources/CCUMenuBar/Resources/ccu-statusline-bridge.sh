#!/usr/bin/env bash
# CCU statusline bridge — Producer A
#
# Claude Code calls this script on each "tick" with session JSON on stdin.
# We extract rate_limits, write them to the shared state file, then forward
# stdin to the user's existing statusline (if configured) so we don't break
# their HUD.
#
# Install: open the Claude Code Usage app and use the "Setup…" menu item — it
# installs this script and configures settings.json for you. To do it by hand:
#   1. Copy this file to ~/.claude/scripts/ccu-statusline-bridge.sh
#   2. chmod +x ~/.claude/scripts/ccu-statusline-bridge.sh
#   3. In ~/.claude/settings.json:
#        "statusLine": {
#          "type": "command",
#          "command": "bash ~/.claude/scripts/ccu-statusline-bridge.sh"
#        }
#
# Chaining an existing statusline: if you already have one, this bridge forwards
# stdin to it so your HUD keeps working. The inner command is resolved from, in
# order of precedence:
#   1. $CCU_INNER_STATUSLINE  (a command string, set in your shell profile)
#   2. ~/.claude/scripts/ccu-inner-statusline  (a one-line file; the Setup flow
#      writes your previous statusLine command here automatically)
#
# Requires: jq. Install with `brew install jq` if missing.

set -uo pipefail

STATE_DIR="${HOME}/Library/Application Support/ClaudeCodeUsage"
STATE_FILE="${STATE_DIR}/state.json"
STATE_TMP="${STATE_FILE}.tmp.$$"
LOG_FILE="${STATE_DIR}/bridge.log"

mkdir -p "${STATE_DIR}"

# Read stdin once into a variable so we can both parse it AND forward it.
INPUT="$(cat)"

# Fail-soft: if jq is missing, write nothing, forward stdin, exit 0.
# Status line going blank because of a missing dep is worse than no update.
if ! command -v jq >/dev/null 2>&1; then
  echo "[$(date -u +%FT%TZ)] jq not found in PATH; skipping write" >> "${LOG_FILE}"
else
  # Extract rate_limits. These fields are only present on Pro/Max plans AFTER
  # the first API call in a session. Before that, jq returns null and we bail.
  #
  # Expected shape (verify against your Claude Code version):
  #   .rate_limits.five_hour.used_percentage   number 0-100
  #   .rate_limits.five_hour.resets_at         unix seconds (integer)
  #   .rate_limits.seven_day.used_percentage   number 0-100
  #   .rate_limits.seven_day.resets_at         unix seconds (integer)
  RATE_LIMITS="$(printf '%s' "${INPUT}" | jq -c '.rate_limits // empty' 2>/dev/null || true)"

  if [[ -n "${RATE_LIMITS}" && "${RATE_LIMITS}" != "null" ]]; then
    # Build the state object. Use // null so missing fields become explicit nulls
    # rather than absent keys — the Swift side expects a consistent shape.
    NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    NEW_STATE="$(printf '%s' "${RATE_LIMITS}" | jq \
      --arg now "${NOW_ISO}" \
      '{
        session: (
          if .five_hour then
            {
              used_pct: (.five_hour.used_percentage // .five_hour.utilization // null),
              resets_at_unix: (.five_hour.resets_at // null)
            }
          else null end
        ),
        weekly: (
          if .seven_day then
            {
              used_pct: (.seven_day.used_percentage // .seven_day.utilization // null),
              resets_at_unix: (.seven_day.resets_at // null)
            }
          else null end
        ),
        source: "statusline",
        updated_at: $now
      }' 2>/dev/null)"

    if [[ -n "${NEW_STATE}" ]]; then
      # Atomic write: temp file + rename. Avoids partial reads from the Swift app.
      printf '%s\n' "${NEW_STATE}" > "${STATE_TMP}" && mv -f "${STATE_TMP}" "${STATE_FILE}"
    else
      echo "[$(date -u +%FT%TZ)] jq transform failed; raw rate_limits=${RATE_LIMITS}" >> "${LOG_FILE}"
    fi
  else
    # No rate_limits in input — common before the first API call, or on plans
    # that don't expose them. Stay silent; don't overwrite good state with empty.
    :
  fi
fi

# Chain to the user's inner statusline if configured. Otherwise emit a minimal
# default so the user's terminal status bar isn't blank.
INNER_CMD="${CCU_INNER_STATUSLINE:-}"
INNER_SIDECAR="${HOME}/.claude/scripts/ccu-inner-statusline"
if [[ -z "${INNER_CMD}" && -f "${INNER_SIDECAR}" ]]; then
  # First non-empty, non-comment line of the sidecar file.
  INNER_CMD="$(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "${INNER_SIDECAR}" 2>/dev/null | head -n 1)"
fi

if [[ -n "${INNER_CMD}" ]]; then
  # Run via `sh -c` so both bare paths and full commands ("bash /path foo") work.
  printf '%s\n' "${INPUT}" | sh -c "${INNER_CMD}"
else
  # Minimal default: model name + context % if available, else nothing.
  printf '%s' "${INPUT}" | jq -r '
    [
      (.model.display_name // empty),
      (if .context_window.used_percentage != null
        then "ctx \(.context_window.used_percentage)%"
        else empty end)
    ] | map(select(. != "")) | join(" │ ")
  ' 2>/dev/null || true
fi

exit 0
