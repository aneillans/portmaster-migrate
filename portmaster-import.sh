#!/usr/bin/env bash
# portmaster-import.sh — re-apply a settings bundle produced by
# portmaster-export.sh onto a (different) machine's Portmaster install,
# via Portmaster's official local "sync" API.
#
# Requirements on the TARGET machine while running the import:
#   - Portmaster core service running and reachable at --api-url
#   - Portmaster's API must trust this process (same requirement as export):
#       temporarily enable "Development Mode" in Portmaster Settings, or
#       pass --api-key with a key created under Portmaster Settings > API.
#
# Usage:
#   ./portmaster-import.sh BUNDLE.json [options]
#
# Options:
#   --api-url URL        Portmaster API base (default http://127.0.0.1:817)
#   --api-key KEY        API key, if not using Development Mode
#   --dry-run            Validate only; makes no changes (recommended first run)
#   --reset               Wipe existing settings on each target before applying
#                          (both global and per-profile) instead of merging.
#   --allow-replace       Allow replacing an existing profile outright (profiles
#                          only; default is to merge into a matching profile).
#   --allow-unknown        Accept settings keys this Portmaster version doesn't
#                           recognize (useful across differing Portmaster versions)
#                           instead of failing on them.
#   --skip-profiles        Only import global settings, skip per-app profiles.
#   --only PROFILE_ID      Import only this one profile id (repeatable).
#                          Omit to import every profile in the bundle.

set -euo pipefail

API_URL="http://127.0.0.1:817"
API_KEY=""
DRY_RUN=0
RESET=0
ALLOW_REPLACE=0
ALLOW_UNKNOWN=0
SKIP_PROFILES=0
ONLY_IDS=()
BUNDLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-url) API_URL="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --reset) RESET=1; shift ;;
    --allow-replace) ALLOW_REPLACE=1; shift ;;
    --allow-unknown) ALLOW_UNKNOWN=1; shift ;;
    --skip-profiles) SKIP_PROFILES=1; shift ;;
    --only) ONLY_IDS+=("$2"); shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *)
      if [[ -z "$BUNDLE" ]]; then BUNDLE="$1"; shift; else echo "Unknown argument: $1" >&2; exit 1; fi
      ;;
  esac
done

if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "Usage: $0 BUNDLE.json [options]  (run with --help for details)" >&2
  exit 1
fi
if ! jq -e '.bundle_type == "portmaster-settings-bundle"' "$BUNDLE" >/dev/null 2>&1; then
  echo "ERROR: $BUNDLE doesn't look like a portmaster-export.sh bundle." >&2
  exit 1
fi

AUTH_HEADER=()
[[ -n "$API_KEY" ]] && AUTH_HEADER=(-H "Authorization: Bearer $API_KEY")

qs_bool() { [[ "$1" == "1" ]] && echo "true" || echo "false"; }

echo "==> Checking Portmaster API at $API_URL" >&2
probe_code="$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH_HEADER[@]}" "$API_URL/api/v1/endpoints" || true)"
if [[ "$probe_code" != "200" ]]; then
  echo "ERROR: could not reach Portmaster API (HTTP $probe_code). Is portmaster.service running?" >&2
  exit 1
fi

[[ "$DRY_RUN" == "1" ]] && echo "==> DRY RUN: validating only, no changes will be made" >&2

fail_with_auth_help() {
  echo "ERROR: Portmaster API rejected this request (unauthorized)." >&2
  echo "Enable 'Development Mode' in Portmaster Settings, or pass --api-key" >&2
  echo "with a key created under Portmaster Settings > API, then re-run." >&2
  exit 1
}

echo "==> Importing global settings" >&2
global_body="$(jq -c '.global' "$BUNDLE")"
url="$API_URL/api/v1/sync/settings/import?to=global&validate=$(qs_bool "$DRY_RUN")&reset=$(qs_bool "$RESET")&allowUnknown=$(qs_bool "$ALLOW_UNKNOWN")"
resp="$(curl -sS -X POST "${AUTH_HEADER[@]}" -H 'Content-Type: application/json' --data-raw "$global_body" -w '\n%{http_code}' "$url")"
code="$(tail -n1 <<<"$resp")"; body="$(sed '$d' <<<"$resp")"
if [[ "$code" == "403" ]]; then fail_with_auth_help; fi
if [[ "$code" != "200" ]]; then
  echo "ERROR: global settings import failed (HTTP $code): $body" >&2
  exit 1
fi
echo "  -> $body" >&2

if [[ "$SKIP_PROFILES" == "1" ]]; then
  echo "==> Skipping profiles (--skip-profiles)" >&2
else
  icount="$(jq '.internal_settings // [] | length' "$BUNDLE")"
  if [[ "$icount" -gt 0 ]]; then
    echo "==> Importing $icount built-in profile override(s)" >&2
    for i in $(seq 0 $((icount - 1))); do
      entry="$(jq -c ".internal_settings[$i]" "$BUNDLE")"
      pid="$(jq -r '.id' <<<"$entry")"
      pname="$(jq -r '.name // .id' <<<"$entry")"
      settings="$(jq -c '.settings' <<<"$entry")"

      if [[ ${#ONLY_IDS[@]} -gt 0 ]]; then
        match=0
        for want in "${ONLY_IDS[@]}"; do [[ "$want" == "$pid" ]] && match=1; done
        [[ "$match" == "0" ]] && { echo "  - skip $pid ($pname) — not in --only list" >&2; continue; }
      fi

      url="$API_URL/api/v1/sync/settings/import?to=$pid&validate=$(qs_bool "$DRY_RUN")&reset=$(qs_bool "$RESET")&allowUnknown=$(qs_bool "$ALLOW_UNKNOWN")"
      resp="$(curl -sS -X POST "${AUTH_HEADER[@]}" -H 'Content-Type: application/json' --data-raw "$settings" -w '\n%{http_code}' "$url")"
      code="$(tail -n1 <<<"$resp")"; body="$(sed '$d' <<<"$resp")"
      if [[ "$code" == "403" ]]; then fail_with_auth_help; fi
      if [[ "$code" != "200" ]]; then
        echo "  - FAILED $pid ($pname): HTTP $code: $body" >&2
        continue
      fi
      echo "  - OK $pid ($pname): $body" >&2
    done
  fi

  count="$(jq '.profiles | length' "$BUNDLE")"
  echo "==> Importing $count app profile(s)" >&2
  for i in $(seq 0 $((count - 1))); do
    prof="$(jq -c ".profiles[$i]" "$BUNDLE")"
    pid="$(jq -r '.source + "/" + .id' <<<"$prof")"
    pname="$(jq -r '.name // .id' <<<"$prof")"

    if [[ ${#ONLY_IDS[@]} -gt 0 ]]; then
      match=0
      for want in "${ONLY_IDS[@]}"; do [[ "$want" == "$pid" ]] && match=1; done
      [[ "$match" == "0" ]] && { echo "  - skip $pid ($pname) — not in --only list" >&2; continue; }
    fi

    url="$API_URL/api/v1/sync/profile/import?validate=$(qs_bool "$DRY_RUN")&reset=$(qs_bool "$RESET")&allowReplace=$(qs_bool "$ALLOW_REPLACE")&allowUnknown=$(qs_bool "$ALLOW_UNKNOWN")"
    resp="$(curl -sS -X POST "${AUTH_HEADER[@]}" -H 'Content-Type: application/json' --data-raw "$prof" -w '\n%{http_code}' "$url")"
    code="$(tail -n1 <<<"$resp")"; body="$(sed '$d' <<<"$resp")"
    if [[ "$code" == "403" ]]; then fail_with_auth_help; fi
    if [[ "$code" != "200" ]]; then
      echo "  - FAILED $pid ($pname): HTTP $code: $body" >&2
      continue
    fi
    echo "  - OK $pid ($pname): $body" >&2
  done
fi

spn_account="$(jq -c '.spn_account_info // null' "$BUNDLE")"
if [[ "$spn_account" != "null" ]]; then
  echo "==> Reminder: SPN account login was NOT imported (it can't be exported)." >&2
  echo "    The source machine was logged in as '$(jq -r '.username' <<<"$spn_account")'" >&2
  echo "    ($(jq -r '.plan' <<<"$spn_account")). Log into that same Safing account in" >&2
  echo "    Portmaster's UI here for SPN to actually connect — it'll register this" >&2
  echo "    machine as an additional device on the existing subscription." >&2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> Dry run complete. Re-run without --dry-run to apply." >&2
else
  echo "==> Import complete. Some settings may require a Portmaster restart to take effect." >&2
fi
