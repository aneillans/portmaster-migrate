#!/usr/bin/env bash
# portmaster-export.sh — extract Portmaster firewall settings via its local API
# so they can be re-applied on another machine with portmaster-import.sh.
#
# Uses Portmaster's official "sync" API (Export Settings / Export App Profile),
# the same mechanism the Portmaster UI uses for its own Settings > Export/Import.
#
# Requirements on THIS machine while running the export:
#   - Portmaster core service running and reachable at --api-url (default below)
#   - Portmaster's API must trust this process. Either:
#       a) run this script via/under the Portmaster UI's allowed path (rare), or
#       b) temporarily enable "Development Mode" in Portmaster's Settings, or
#       c) create an API key in Portmaster Settings > API and pass --api-key
#     Development Mode / the API key can be turned off again right after export;
#     the exported file itself carries no credentials.
#
# Usage:
#   ./portmaster-export.sh [-o output.json] [--api-url URL] [--api-key KEY]
#                           [--profile SRC/ID ...] [--include-defaults]
#
#   --profile SRC/ID     Force-include a specific profile (e.g. local/_portmaster),
#                         in addition to what's auto-discovered. Repeatable.
#   --include-defaults   Also export profiles that have no customized settings
#                         (normally skipped, since there's nothing to re-apply).
#
# Output: a single JSON bundle containing the global settings export and one
# export per app profile that has custom (non-default) settings.

set -euo pipefail

API_URL="http://127.0.0.1:817"
API_KEY=""
OUT_FILE="portmaster-settings-$(date +%Y%m%d-%H%M%S).json"
INCLUDE_DEFAULTS=0
EXTRA_PROFILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUT_FILE="$2"; shift 2 ;;
    --api-url) API_URL="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --profile) EXTRA_PROFILES+=("$2"); shift 2 ;;
    --include-defaults) INCLUDE_DEFAULTS=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

AUTH_HEADER=()
[[ -n "$API_KEY" ]] && AUTH_HEADER=(-H "Authorization: Bearer $API_KEY")

curl_api() {
  # curl_api METHOD PATH [extra curl args...]
  local method="$1" path="$2"; shift 2
  curl -sS -X "$method" "${AUTH_HEADER[@]}" "$API_URL/api/v1/$path" "$@"
}

fail_with_auth_help() {
  echo "ERROR: Portmaster API rejected this request (unauthorized)." >&2
  echo "Enable 'Development Mode' in Portmaster Settings, or pass --api-key" >&2
  echo "with a key created under Portmaster Settings > API, then re-run." >&2
  exit 1
}

echo "==> Checking Portmaster API at $API_URL" >&2
probe="$(curl_api GET endpoints -w '\n%{http_code}' -o /tmp/.pm_probe.$$ 2>/dev/null || true)"
probe_code="$(tail -n1 <<<"$probe")"
rm -f /tmp/.pm_probe.$$
if [[ "$probe_code" != "200" ]]; then
  echo "ERROR: could not reach Portmaster API (HTTP $probe_code). Is portmaster.service running?" >&2
  exit 1
fi

echo "==> Exporting global settings" >&2
global_json="$(curl_api GET 'sync/settings/export?from=global' -w '\n%{http_code}')"
global_code="$(tail -n1 <<<"$global_json")"
global_body="$(sed '$d' <<<"$global_json")"
if [[ "$global_code" == "403" ]]; then fail_with_auth_help; fi
if [[ "$global_code" != "200" ]]; then
  echo "ERROR: global settings export failed (HTTP $global_code): $global_body" >&2
  exit 1
fi

echo "==> Checking SPN account status" >&2
# SPN's on/off toggle, routing algorithm and usage rules are ordinary config
# keys and are already captured above. Being able to actually *use* SPN also
# requires an active login to a Safing account/subscription, though — that's
# session/account state, not a config value, and there's no export endpoint
# for it (rightly: it's not something that should be dumped as JSON and
# replayed elsewhere). We record non-secret info about it here purely so the
# import step can remind you it needs a manual login on the target machine.
spn_account_json="null"
acct_resp="$(curl_api GET 'spn/account/user/profile' -w '\n%{http_code}' 2>/dev/null || true)"
acct_code="$(tail -n1 <<<"$acct_resp")"
acct_body="$(sed '$d' <<<"$acct_resp")"
if [[ "$acct_code" == "200" ]]; then
  spn_account_json="$(jq -c '{username, state, plan: .current_plan.name, subscription_ends_at: .subscription.ends_at, device_name: .device.name}' <<<"$acct_body" 2>/dev/null || echo null)"
  echo "  - logged in as $(jq -r '.username // "?"' <<<"$acct_body") ($(jq -r '.current_plan.name // "?"' <<<"$acct_body")) — this login itself can't be exported, see note at the end" >&2
else
  echo "  - not logged in to an SPN account (or SPN not in use) — nothing to note" >&2
fi

echo "==> Discovering app profiles with recent activity" >&2
netq="$(curl_api POST netquery/query -H 'Content-Type: application/json' -d '{}')"
mapfile -t discovered < <(jq -r '.results[]?.profile // empty' <<<"$netq" | sort -u)

# Merge discovered + manually-requested profiles, de-duplicated.
declare -A profile_set
for p in "${discovered[@]}" "${EXTRA_PROFILES[@]:-}"; do
  [[ -n "$p" ]] && profile_set["$p"]=1
done

echo "==> Found ${#profile_set[@]} candidate profile(s); fetching each" >&2
# Two kinds of entries end up in the bundle:
#  - "profiles": full app-profile exports (fingerprints + name + icon + settings)
#    for regular, third-party apps — needed so the target machine can match/create
#    the profile for a binary it may never have seen before.
#  - "internal_settings": settings-only exports (no fingerprints) for Portmaster's
#    own built-in profiles (Portmaster Core Service, System DNS Client, Network
#    Noise, ...), which already exist by fixed ID on every install and can't be
#    imported via the profile API (they carry no fingerprints to validate).
profiles_json="[]"
internal_json="[]"
for pid in "${!profile_set[@]}"; do
  resp="$(curl_api GET "sync/profile/export" -G --data-urlencode "id=$pid" -w '\n%{http_code}')"
  code="$(tail -n1 <<<"$resp")"
  body="$(sed '$d' <<<"$resp")"
  if [[ "$code" == "403" ]]; then fail_with_auth_help; fi
  if [[ "$code" != "200" ]]; then
    echo "  - skip $pid (HTTP $code)" >&2
    continue
  fi
  has_config="$(jq -r 'has("config") and (.config != {})' <<<"$body")"
  # Profiles with no fingerprints (Portmaster's own built-ins: the core
  # service, the system DNS client, network noise, ...) can't go through
  # the profile-import path (it requires fingerprints to match against) —
  # route those through the settings-only path instead.
  is_internal="$(jq -r '(.internal == true) or ((.fingerprints // []) | length == 0)' <<<"$body")"
  name="$(jq -r '.name // .id' <<<"$body")"

  if [[ "$has_config" != "true" && "$INCLUDE_DEFAULTS" != "1" ]]; then
    echo "  - skip $pid ($name) — no customized settings" >&2
    continue
  fi

  if [[ "$is_internal" == "true" ]]; then
    settings_resp="$(curl_api GET "sync/settings/export" -G --data-urlencode "from=$pid" -w '\n%{http_code}')"
    settings_code="$(tail -n1 <<<"$settings_resp")"
    settings_body="$(sed '$d' <<<"$settings_resp")"
    if [[ "$settings_code" != "200" ]]; then
      echo "  - skip $pid ($name) — settings export failed (HTTP $settings_code)" >&2
      continue
    fi
    echo "  - include $pid ($name) [built-in profile, settings-only]" >&2
    entry="$(jq -n --arg id "$pid" --arg name "$name" --argjson settings "$settings_body" \
      '{id: $id, name: $name, settings: $settings}')"
    internal_json="$(jq --argjson e "$entry" '. + [$e]' <<<"$internal_json")"
  else
    echo "  - include $pid ($name)$( [[ "$has_config" == "false" ]] && echo ' [defaults only]')" >&2
    profiles_json="$(jq --argjson p "$body" '. + [$p]' <<<"$profiles_json")"
  fi
done

hostname_val="$(hostname 2>/dev/null || echo unknown)"
jq -n \
  --argjson global "$global_body" \
  --argjson profiles "$profiles_json" \
  --argjson internal_settings "$internal_json" \
  --argjson spn_account "$spn_account_json" \
  --arg exported_at "$(date -Iseconds)" \
  --arg source_host "$hostname_val" \
  '{
     bundle_type: "portmaster-settings-bundle",
     bundle_version: 1,
     exported_at: $exported_at,
     source_host: $source_host,
     global: $global,
     profiles: $profiles,
     internal_settings: $internal_settings,
     spn_account_info: $spn_account
   }' > "$OUT_FILE"

echo "==> Wrote $OUT_FILE" >&2
echo "    global settings:            1" >&2
echo "    app profiles:               $(jq '.profiles | length' "$OUT_FILE")" >&2
echo "    built-in profile overrides: $(jq '.internal_settings | length' "$OUT_FILE")" >&2

if [[ "$(jq -r '.global.config.core.devMode // false' "$OUT_FILE")" == "true" ]]; then
  echo "NOTE: core.devMode=true is in the export. If you only turned Development" >&2
  echo "      Mode on to allow this export/import (rather than as a setting you" >&2
  echo "      actually want on the target), remove that key from $OUT_FILE" >&2
  echo "      (global.config.core.devMode) before importing." >&2
fi

if [[ "$spn_account_json" != "null" ]]; then
  echo "NOTE: SPN is logged in as '$(jq -r '.username' <<<"$spn_account_json")' on this machine." >&2
  echo "      This bundle includes your SPN on/off, routing-algorithm and usage-rule" >&2
  echo "      settings, but NOT the account login itself — that can't be exported." >&2
  echo "      On the target machine, log into the same Safing account in Portmaster's" >&2
  echo "      UI (it will register as an additional device on your subscription)." >&2
fi

echo "Copy this file to the target machine and run portmaster-import.sh against it." >&2
