# Pi4 ChatGPT session maintenance

## Design

`modules/pi4-chatgpt-auth.nix` adds a runtime-only credential manager and daily
systemd timer to the Colmena `pi4` node, not the reusable SD image. The existing
app-specific OpenAI registration is preserved; no workstation/Codex/Hermes
credentials are imported, and no existing API key is read.

- Package/CLI: `pi4-chatgpt-auth`
- Service: `pi4-chatgpt-auth-refresh.service`
- Timer: `pi4-chatgpt-auth-refresh.timer`
- Canonical private state: `/var/lib/zeroclaw/siwc-test-state`

The historical state-directory name is retained intentionally to avoid copying
or duplicating live rotating credentials. Files remain owned by `zeroclaw`, with
0700 directory and 0600 files. The compatibility entrypoint under
`/var/lib/zeroclaw/siwc-login-test/run` delegates to the packaged implementation.
Do not run the archived prototype Python file directly against live credentials.
The packaged wrapper rejects state-path overrides, including abbreviated forms.

The timer uses `OnCalendar=daily` in the Pi's configured timezone,
`Persistent=true`, up to ten minutes of randomized delay and one-minute
accuracy. It catches up missed calendar runs after startup. This maintains the
renewable session while idle; it does not keep an access token valid all day.
CLI model/probe operations use the same locked refresh path before requests.
ZeroClaw still requires separate integration with that credential manager.

## Refresh transaction

All operations use the same exclusive state-file lock. Refresh observes the
provider's `earliest_refresh_at` and the local near-expiry window. There is no
force-early-rotation option.

A private, fsynced `refresh-inflight.json` marker is written before a refresh
POST. Replacement credentials and a generation identifier are saved atomically
and fsynced, read back, then the marker is removed. If interrupted after the
credential write, matching generation metadata permits cleanup without replay.
If interrupted before the outcome is durable, further rotation is blocked.
A successful fresh login clears an unresolved marker only after validation and
credential persistence.

Retries are conservative: three total attempts with five/fifteen-second backoff
only for connection-establishment timeouts or safe read-only discovery/JWKS
failures. A read timeout, generic refresh POST HTTP 429/502/503/504, malformed
successful response, or failed replacement write can hide a completed rotation.
Those preserve the outcome marker and block automatic reuse of the old refresh
token. Do not delete the marker merely to make retries run; diagnose or perform
a fresh app authorization.

Provider-confirmed terminal refresh errors clear access/refresh/ID tokens while
retaining the host/client/account mapping and recording `login_required`.
`invalid_client` is a configuration error, not proof of revoked user consent.
No inference or automatic API-key fallback occurs in the scheduled refresh job.

## Isolation

The service runs as `zeroclaw`, with no capabilities or privilege escalation,
a read-only system, private temporary/device namespaces, and only its state
directory writable. It has a five-minute runtime limit, 256 MiB memory limit,
32-task limit, and core dumps disabled. It does not receive the root-only
1Password service-account token. Account administrators with root access can
still read local credentials; these permissions do not isolate secrets from root.

Secrets never enter Nix expressions, environment definitions, arguments, Git,
or logs. Logs contain fixed status/error categories and non-secret timestamps.
The helper disables ambient proxy/netrc credentials and rejects redirects and
unexpected network destinations. Operator probes should retain an outer timeout;
the inherited model-stream parser is not a production streaming integration.

## Operations after activation

```sh
systemctl status pi4-chatgpt-auth-refresh.timer
systemctl list-timers pi4-chatgpt-auth-refresh.timer
sudo systemctl start pi4-chatgpt-auth-refresh.service
sudo journalctl -u pi4-chatgpt-auth-refresh.service --no-pager
sudo -H -u zeroclaw /run/current-system/sw/bin/pi4-chatgpt-auth status
sudo -H -u zeroclaw /run/current-system/sw/bin/pi4-chatgpt-auth models
sudo -H -u zeroclaw timeout --kill-after=5s 150s \
  /run/current-system/sw/bin/pi4-chatgpt-auth probe --model gpt-6-astra
```

`refresh=not_due` is a successful no-op, not evidence of rotation. Successful
rotation records sanitized metadata in `last-refresh.json`. A probe requires
`response.completed`; its result is recorded in `last-probe.json`.

If login is required, run the packaged `login` command as zeroclaw and forward
127.0.0.1:18765 over SSH for the workstation browser, as in the spike README.
Retain the existing registration/host mapping. Never paste callback URLs or
credential records into chat. Disconnect the application in ChatGPT Settings to
revoke it. This helper does not yet provide a revoke command or external alert
channel: failures are visible through systemd/journal and the CLI.

## Validation

```sh
nix eval --impure --no-write-lock-file --json --file tests/pi4-chatgpt-auth.nix
python3 tests/evaluate.py
nix eval --impure --json --file tests/pi4-secrets.nix
nix eval --impure --json --file tests/zeroclaw-account.nix
nix eval --impure --json --file tests/remote-access.nix
```

The package's Nix build runs the offline unittest suite, wrapper help, and
state-path rejection checks. The suite contains 17 test methods, including
synthetic signed identity cases, callback handling, durable state/locking,
CLI refresh orchestration, classified retries, terminal revocation, gateway
ambiguity, write failure, and post-write crash recovery. These fixture tests
are not substituted for a real provider refresh.

All four original VM derivations and original lock nodes must remain unchanged.
A sandboxed ARM package/system build passed, including the 17 tests. A transient
service with the intended hardening returned `not_due`, Result=success,
ExecMainStatus=0. It was stopped and removed after inspection.

## Verified rollout

The real refresh ran at the permitted time and succeeded: the refresh token was
replaced, the access-token expiry advanced, and the private credential file was
read back successfully. A subsequent `gpt-6-astra` request returned
`response.completed` and exactly `Hello from Pi4.` using the replacement
credentials. Sanitized `last-refresh.json` and `last-probe.json` were independently
read back; no in-flight marker remained. The transient verification unit reported
`Result=success` and `ExecMainStatus=0` and has since been garbage-collected.

Pinned Colmena `apply switch --impure --on pi4 --no-keys` then succeeded. Both
the active and boot-default profile resolve to:

`/nix/store/kxb17ic48vyrqfjv2lhrv4icny0v1fwf-nixos-system-pi4-26.05pre-git`

The regular timer is enabled and active, with `Persistent=yes` and daily calendar
scheduling. Its first observed scheduled run is 2026-10-26 00:00:14 PDT (jitter
may change after subsequent scheduling). A manual invocation of the installed
service succeeded with `refresh=not_due`, correctly avoiding another immediate
rotation. Runtime ownership/hardening properties were read back from systemd.

SSH, Tailscale, Herdr, root-only SOPS bootstrap access, and zeroclaw isolation
remain healthy. No failed system/user units were found. Boot ID was unchanged;
no reboot was performed. All four VM derivations and prior lock nodes remain
unchanged. No commit, push, ZeroClaw daemon, or API-key fetcher was included.

The advertised legacy test wrapper now delegates to the system-profile command,
so future Nix upgrades and manual commands share the same implementation. The
original prototype Python files are archival only. Further work is ZeroClaw
integration and optional alert delivery/reboot testing—not another login merely
to keep this session renewable.
