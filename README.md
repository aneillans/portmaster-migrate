# Portmaster settings migration

Extracts this machine's Portmaster firewall configuration (global settings +
per-app rules) via Portmaster's own local API — the same mechanism its UI
uses for Settings → Export/Import — and re-applies it on another machine.

## Why the API, not the raw config files

Portmaster's real state lives in `/var/lib/portmaster/config.json` (root-only)
and an internal key/value store under `/var/lib/portmaster/databases/`
(root-only, custom binary format — not something to hand-edit or diff).
Portmaster exposes a purpose-built export/import API for exactly this
migration use case, so these scripts use that instead of touching those files.

## One-time requirement: let the API trust the caller

Portmaster's local API (`127.0.0.1:817`) checks the calling process's path
and rejects anything that isn't Portmaster itself, unless you either:

- **Development Mode** — Portmaster Settings → search "Development Mode" →
  enable. Turn it back off once you're done exporting/importing.
- **An API key** — Portmaster Settings → API → create a key, then pass
  `--api-key YOUR_KEY` to either script.

Needed on **both** the source machine (for export) and the target machine
(for import).

## Usage

On the source machine:

```sh
./portmaster-export.sh -o portmaster-settings.json
```

Copy `portmaster-settings.json` to the target machine, then:

```sh
./portmaster-import.sh portmaster-settings.json --dry-run   # validate first
./portmaster-import.sh portmaster-settings.json             # apply for real
```

Useful flags (see `--help` on either script for the full list):

- `--profile SRC/ID` (export) — force-include a profile the auto-discovery
  missed (discovery is based on recently-seen connections, so an app that
  hasn't run in a while with a custom rule could be skipped).
- `--dry-run` (import) — validate only, no changes.
- `--reset` (import) — replace rather than merge existing settings.
- `--allow-unknown` (import) — don't fail on settings keys the target's
  Portmaster version doesn't recognize (useful across version differences).

## SPN: what transfers and what doesn't

SPN's actual *settings* — on/off, routing algorithm (single-hop/double-hop),
exit/transit/home/trust node policies, domain usage rules — are ordinary
config keys and are exported/imported like everything else in `global`.

What does **not** transfer is the SPN account **login** itself (your Safing
account / Portmaster Pro subscription session) — that's account/device state,
not a setting, and Portmaster exposes no export endpoint for it (nor should
it: it's tied to a device-authenticated login, not something to dump as
portable JSON). If the source machine is logged in, the bundle records your
username/plan/subscription end date purely as an informational reminder —
both scripts print a note about it. To make SPN actually connect on the
target, log into that same Safing account via Portmaster's UI there; it
registers as an additional device on your existing subscription.

## What's in the bundle

- `global` — machine-wide settings (DNS, filtering defaults, SPN/exit-node
  policy, etc.)
- `profiles` — full per-app profiles (fingerprints + name + icon + rules) for
  third-party apps, so the target can recognize/create the profile even if
  it's never seen that binary.
- `internal_settings` — settings-only overrides for Portmaster's own built-in
  profiles (the core service itself, the system DNS client, "Network Noise"),
  which exist by fixed ID on every install and don't carry fingerprints.
- `spn_account_info` — informational only (username/plan/subscription end
  date), not a login. See "SPN" below.

Only profiles/settings that differ from Portmaster's defaults are included
(pass `--include-defaults` to export to change that — not usually useful).

If `core.devMode` shows up in the export, the export script will flag it —
that's likely just the toggle you switched on to authorize the export, not a
setting you meant to carry over. Strip it from the JSON before importing if so.

## Caveats

- Auto-discovery of app profiles is best-effort: it comes from Portmaster's
  connection history, so apps that haven't connected recently may be missed.
  Use `--profile` to add specific ones by hand (find the ID by looking up the
  app in the Portmaster UI, or in a prior export's `profiles[].source`+`.id`).
- Some settings may require restarting Portmaster to take effect (the import
  script's output will say `"restartRequired":true` per item when that's the
  case).
