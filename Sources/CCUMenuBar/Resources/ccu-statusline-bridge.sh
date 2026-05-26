#!/usr/bin/env bash
# CCU statusline bridge — Producer for the Claude Code Usage menu bar app.
#
# Claude Code calls this script on each "tick" with session JSON on stdin.
# We extract rate_limits, write them to a shared state file the app watches,
# write a heartbeat file regardless, then forward stdin to the user's existing
# statusline (if any) so we don't break their HUD.
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
# stdin to it so your HUD keeps working. Resolution order:
#   1. $CCU_INNER_STATUSLINE (a command string)
#   2. ~/.claude/scripts/ccu-inner-statusline (the Setup flow writes your prior
#      statusLine command here on install)
#
# Requires: jq. Install with `brew install jq` if missing.

set -uo pipefail

STATE_DIR="${HOME}/Library/Application Support/ClaudeCodeUsage"
STATE_FILE="${STATE_DIR}/state.json"
STATE_TMP="${STATE_FILE}.tmp.$$"
BRIDGE_STATUS_FILE="${STATE_DIR}/bridge-status.json"
BRIDGE_STATUS_TMP="${BRIDGE_STATUS_FILE}.tmp.$$"
LOG_FILE="${STATE_DIR}/bridge.log"

mkdir -p "${STATE_DIR}"

# Resolve jq. Claude Code spawns the statusline command with a stripped PATH,
# so a bare `jq` lookup often fails even when jq is installed — the most
# common cause of "state.json never appears." The app installer substitutes
# @@JQ_PATH@@ with the absolute path it discovered. Fall through to common
# locations and to `command -v` for manual installs.
INSTALLED_JQ="@@JQ_PATH@@"
JQ=""
# If `@@JQ_PATH@@` isn't substituted (manual install), the `-x` test on the
# literal placeholder fails and we fall through to the next candidate.
for candidate in "${CCU_JQ:-}" "${INSTALLED_JQ}" /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    JQ="${candidate}"
    break
  fi
done
if [[ -z "${JQ}" ]] && command -v jq >/dev/null 2>&1; then
  JQ="$(command -v jq)"
fi

INPUT="$(cat)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_bridge_status() {
  local rate_limits_present="$1"
  if [[ -n "${JQ}" ]]; then
    if printf '%s' '{}' | "${JQ}" -c \
        --arg now "${NOW_ISO}" \
        --arg path "${STATE_FILE}" \
        --arg jq "${JQ}" \
        --argjson present "${rate_limits_present}" \
        '{schema_version: 1, bridge_last_seen_at: $now, bridge_path: $path, rate_limits_present: $present, jq_path: $jq}' \
        > "${BRIDGE_STATUS_TMP}" 2>/dev/null; then
      mv -f "${BRIDGE_STATUS_TMP}" "${BRIDGE_STATUS_FILE}"
    else
      rm -f "${BRIDGE_STATUS_TMP}"
    fi
  else
    # No jq — hand-write a minimal heartbeat. Path is under $HOME, so quoting
    # is safe under standard install locations.
    if printf '{"schema_version":1,"bridge_last_seen_at":"%s","bridge_path":"%s","rate_limits_present":false,"jq_path":null}\n' \
        "${NOW_ISO}" "${STATE_FILE}" > "${BRIDGE_STATUS_TMP}"; then
      mv -f "${BRIDGE_STATUS_TMP}" "${BRIDGE_STATUS_FILE}"
    else
      rm -f "${BRIDGE_STATUS_TMP}"
    fi
  fi
}

RATE_LIMITS_PRESENT=false

if [[ -z "${JQ}" ]]; then
  echo "[${NOW_ISO}] jq not found; tried installed=${INSTALLED_JQ}, CCU_JQ=${CCU_JQ:-}, common locations. State.json not updated." >> "${LOG_FILE}"
else
  # Extract rate_limits. These fields are only present on Pro/Max plans AFTER
  # the first API call in a session. Before that, jq returns null and we bail.
  #
  # Expected shape (verify against your Claude Code version):
  #   .rate_limits.five_hour.used_percentage   number 0-100
  #   .rate_limits.five_hour.resets_at         unix seconds (integer)
  #   .rate_limits.seven_day.used_percentage   number 0-100
  #   .rate_limits.seven_day.resets_at         unix seconds (integer)
  RATE_LIMITS="$(printf '%s' "${INPUT}" | "${JQ}" -c '.rate_limits // empty' 2>/dev/null || true)"

  if [[ -n "${RATE_LIMITS}" && "${RATE_LIMITS}" != "null" ]]; then
    NEW_STATE="$(printf '%s' "${RATE_LIMITS}" | "${JQ}" \
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
      printf '%s\n' "${NEW_STATE}" > "${STATE_TMP}" && mv -f "${STATE_TMP}" "${STATE_FILE}"
      RATE_LIMITS_PRESENT=true
    else
      echo "[${NOW_ISO}] jq transform failed; raw rate_limits=${RATE_LIMITS}" >> "${LOG_FILE}"
    fi
  fi
fi

# Heartbeat: always write, even when rate_limits was null. This lets the app
# distinguish "bridge never invoked" from "bridge ran, but no payload."
write_bridge_status "${RATE_LIMITS_PRESENT}"

# Chain to the user's inner statusline if configured. Otherwise emit a minimal
# default so the user's terminal status bar isn't blank.
INNER_CMD="${CCU_INNER_STATUSLINE:-}"
INNER_SIDECAR="${HOME}/.claude/scripts/ccu-inner-statusline"
if [[ -z "${INNER_CMD}" && -f "${INNER_SIDECAR}" ]]; then
  INNER_CMD="$(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "${INNER_SIDECAR}" 2>/dev/null | head -n 1)"
fi

if [[ -n "${INNER_CMD}" ]]; then
  printf '%s\n' "${INPUT}" | sh -c "${INNER_CMD}"
elif [[ -n "${JQ}" ]]; then
  printf '%s' "${INPUT}" | "${JQ}" -r '
    [
      (.model.display_name // empty),
      (if .context_window.used_percentage != null
        then "ctx \(.context_window.used_percentage)%"
        else empty end)
    ] | map(select(. != "")) | join(" │ ")
  ' 2>/dev/null || true
fi

exit 0
