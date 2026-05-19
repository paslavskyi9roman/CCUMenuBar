#!/usr/bin/env bash
# CCU statusline bridge — Producer A
#
# Claude Code calls this script on each "tick" with session JSON on stdin.
# We extract rate_limits, write them to the shared state file, then forward
# stdin to the user's existing statusline (if configured) so we don't break
# their HUD.
#
# Install:
#   1. Copy this file to ~/.claude/scripts/ccu-statusline-bridge.sh
#   2. chmod +x ~/.claude/scripts/ccu-statusline-bridge.sh
#   3. In ~/.claude/settings.json:
#        "statusLine": {
#          "type": "command",
#          "command": "bash ~/.claude/scripts/ccu-statusline-bridge.sh"
#        }
#   4. (Optional) If you already have a statusline script, set:
#        export CCU_INNER_STATUSLINE="/full/path/to/your/script.sh"
#      in your shell profile, and we'll chain to it.
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
  RATE_LIMITS="$(echo "${INPUT}" | jq -c '.rate_limits // empty' 2>/dev/null || true)"

  if [[ -n "${RATE_LIMITS}" && "${RATE_LIMITS}" != "null" ]]; then
    # Build the state object. Use // null so missing fields become explicit nulls
    # rather than absent keys — the Swift side expects a consistent shape.
    NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    NEW_STATE="$(echo "${RATE_LIMITS}" | jq \
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
      echo "${NEW_STATE}" > "${STATE_TMP}" && mv -f "${STATE_TMP}" "${STATE_FILE}"
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
if [[ -n "${CCU_INNER_STATUSLINE:-}" && -x "${CCU_INNER_STATUSLINE}" ]]; then
  echo "${INPUT}" | "${CCU_INNER_STATUSLINE}"
else
  # Minimal default: model name + context % if available, else nothing.
  echo "${INPUT}" | jq -r '
    [
      (.model.display_name // empty),
      (if .context_window.used_percentage != null
        then "ctx \(.context_window.used_percentage)%"
        else empty end)
    ] | map(select(. != "")) | join(" │ ")
  ' 2>/dev/null || true
fi

exit 0
