# Pi4 SIWC adapter and isolated ZeroClaw runtime

## PR readiness and clean-checkout limitations

This configuration is being preserved as a **draft**, not certified as a portable
clean-checkout deployment. The rollout records below are historical and do not
establish that the current tree was deployed or tested against a live provider.

- `packages/zeroclaw-pinned.nix` requires both exact retained Nix store objects
  listed below on the evaluator. There is no repository-contained fetch/rebuild
  path yet. Transfer/retain those objects before evaluation; a clean evaluator
  without them cannot evaluate this Pi configuration.
- `tests/siwc-adapter/regression.py` requires synthetic fixtures in the sibling
  `../spikes/siwc-adapter` workspace, which is not included in this PR. That legacy
  acceptance command is not standalone. Source-mode refresh tests also retain a
  workstation-specific helper path; the Nix package substitutes an immutable path.
- The runtime deadline test currently fails its fixed-HTTP-503 assertion: the
  supervisor starts its hard-kill clock before the fork, while the child arms its
  full-duration cooperative timer afterward. SIGKILL can therefore win before the
  child emits the error. The offline reproduction retained the refresh ambiguity
  marker and released the lock, but did not deliver the promised fixed error.
  This remains a merge blocker; the test has not been weakened.
- The Nix assertions now use `f.colmenaHive`, matching the updated main branch.
- The paired-gateway harness deletes only sessions positively acknowledged as
  newly created by that run; resumed/unconfirmed sessions are preserved.

Do not merge as reproducible deployment packaging until the store and fixture
portability requirements are resolved. Paperclip is not part of this change.

## Status and boundary

Live integration accepted on the Pi after Pi-only Colmena activation. Real
`gpt-5.6-sol` plaintext inference, calculator execution plus follow-up inference,
on-demand renewal of an expired access token, and service restart recovery passed.
No reauthorization, reboot, commit, or push was performed. No 872000-token provider
request/load benchmark or cross-turn reasoning-persistence claim is made.

Final deployed system:
`/nix/store/na5nhyxw8rksg12glapczgg7sgmfi5vi-nixos-system-pi4-26.05pre-git`

Final adapter:
`/nix/store/adb5zlcg5m53ivh95jjh0piz2y3r771s-pi4-siwc-adapter-1`

Packaged source SHA-256:
`9cc9bf81d75d6d8c253002ef21f42cad58deb9b040fe6a5fd58112ad9faaddfd`

The initial independent GPT review passed. A second GPT worker debated and
implemented the user-approved empty-output exception below; the coordinator
reviewed its diff and independently reran final packaged acceptance before deployment.

Pi-only `modules/pi4-siwc-adapter.nix` imports `modules/pi4-zeroclaw.nix`.
The original `zeroclaw` account and refresh timer retain the single canonical
OAuth directory `/var/lib/zeroclaw/siwc-test-state`. Neither the shared helper nor
its timer module is changed. The adapter imports the very same immutable helper
source as `pi4-chatgpt-auth`; every refresh holds its existing exclusive lock.

`zeroclaw-agent` is a distinct locked/nologin account with no supplementary groups,
SSH keys, linger, or sudo grant. Its private persistent home is
`/var/lib/zeroclaw-agent`; it cannot read the credential owner's home. The daemon
unit additionally masks `/var/lib/zeroclaw` and hides other users' `/proc` entries.
Root remains trusted. The agent's local capability intentionally permits inference,
not direct OAuth-state access.

## Runtime-only capability and startup

`pi4-siwc-runtime.service` runs the root provisioner once before either consumer.
It creates a root-owned 0711 `/run/pi4-siwc`, a private root master capability,
root-owned 0750 per-group directories, and atomic 0600 per-owner publications:

- `/run/pi4-siwc/adapter/capability`: owned by `zeroclaw`.
- `/run/pi4-siwc/agent/config.toml`: owned by `zeroclaw-agent`, containing only the
  local capability as `api_key`, never an OAuth token.

Capability values never enter Nix expressions/store contents, command arguments,
environment variables, or logs. The master survives unit restarts but not reboot.
Restarting provisioning republishes the same capability. Missing/corrupt/unsafe
existing state fails closed; dependent consumers require successful provisioning.
`PartOf`/`BindsTo` coordinate restarts/stops. Adapter `Upholds` restores the client
when the adapter becomes active. Live restarts of the agent, adapter, and runtime
provisioner each recovered the healthy chain and retained the same capability.

ZeroClaw 0.8.6 cannot boot with an entirely read-only config directory. Its
`--config-dir` overrides `ZEROCLAW_DATA_DIR` and creates `data`, `shared`, and
`agents` underneath its installation directory. Therefore the agent's pre-start
step copies the canonical config into private writable `/run/zeroclaw-agent`, and
creates controlled symlinks for those three directories to the private persistent
home. Do not set `ZEROCLAW_DATA_DIR` alongside this CLI option. Config normalization,
local secret files and config copies stay in `/run`, not persistent storage. Native
OAuth profiles are neither imported nor provisioned; pre-start refuses an existing
runtime `auth-profiles.json` rather than using it.

The actual ARM binary was exercised with separate mapped UIDs, a read-only
canonical config mount, writable runtime copy, and persistent symlink targets:
config read-back and daemon `/health` returned success; persistent data was created;
no capability was found in persistent files or output and no OAuth profile appeared.
This is not a full systemd sandbox or reboot test.

The adapter binds only `127.0.0.1:18766`; startup validates capability ownership,
mode/type/content through `O_NOFOLLOW` + `fstat` on the opened descriptor. A bounded
socket readiness check finishes before the agent starts. The agent gateway binds
only `127.0.0.1:42617` with pairing required. No firewall ports are added. Service
stdout/stderr are disabled; the adapter decision log is unset. Pairing remains
required. The deployed generation still has no persistent pairing store; the local-only
Stage 2 candidate below has not been activated or reboot-tested.

## Local Stage 2 pairing persistence candidate (not deployed)

The candidate persists only ZeroClaw's native `gateway.paired_tokens` values in
`/var/lib/zeroclaw-agent/gateway-pairing.json`. The pinned implementation hashes raw
bearers with SHA-256 and stores lowercase hex (`pairing.rs:818-825`). The JSON schema
is exactly a version plus an array of unique lowercase 64-hex hashes. It never stores
the whole runtime config, a raw paired bearer, OAuth state, or the outbound adapter
capability.

`pi4-zeroclaw-pairing-state` opens parent directories and files with no-follow and
nonblocking semantics, validates regular-file ownership and exact 0600 mode, bounds
input size and hash count, rejects malformed/duplicate/raw/uppercase values, and
rejects a value literally equal to the raw canonical `api_key` read separately from
`/run/pi4-siwc/agent/config.toml` in both merge and snapshot operations. It never
trusts the active runtime copy for that comparison because ZeroClaw may encrypt its
`api_key`. Writes use a same-directory 0600 temporary file, file and directory
`fsync`, and atomic replacement. Success is silent and failure output contains no
values.

Pre-start still installs the fresh provisioned runtime template, preserving its new
runtime-only adapter capability, then merges the private hash set. A missing store
means initially unpaired; a malformed existing store prevents daemon startup. No
provisioner or template change is needed because only the agent's private writable
runtime copy is augmented. A `systemd.path` watcher starts after the daemon reaches
active state and triggers a oneshot bounded by ten-second runtime, startup, and stop
timeouts. Reverse ordering
stops that watcher before the daemon; `ExecStopPost` performs a final snapshot before
RuntimeDirectory cleanup. Empty native sets are written, so revocation survives the
next graceful restart.

Local synthetic tests cover fresh-config restart, empty-set revocation, malformed and
oversized stores, count/type bounds, raw/uppercase/capability-alias rejection,
symlinks, unsafe mode, atomic-write failure, output leakage, actual-template semantic
roundtrip, and distinct UIDs in a mapped user namespace. Nix evaluation asserts the
path/service relationship, stop flush, bounds, unchanged agent resource limits,
loopback firewall boundary, and image exclusion.

Unresolved until deployment review and explicit activation are real-systemd timing
properties: `PathChanged` event coalescing for ZeroClaw's atomic config replacement,
the watcher-active gap immediately after the daemon becomes active, interaction
between an already-running snapshot and stop ordering, and abrupt power loss before
the asynchronous oneshot completes. The stop flush covers graceful restart/reboot,
not sudden power loss. Do not claim persistent pairing until these are exercised.

The paired acceptance follow-up now stays on the same authenticated `/ws/chat`
connection; it no longer uses `/webhook` and does not relax the adapter's streaming
requirement. SQLite auto-save consolidation remains enabled. Its exact runtime
provider path is unverified: `requires_openai_auth` may select
`OpenAiCodexModelProvider`, whose nominal non-stream chat implementation can still
send `stream=true`. Do not claim either successful consolidation or an adapter
rejection without runtime evidence. Two successful WebSocket turns therefore
conservatively reserve two additional background attempts for this ambiguity: any
later live run would require authorization for a five-small-request run cap (two
calculator, one follow-up, two background), making the conservative cumulative
ceiling nine. The four Stage 1 attempts remain the recorded historical count; the
proposed five-request allowance is not active.

## Resource and completion safety

Defaults explicitly passed by the service:

- Request body: 32 MiB; response stream: 8 MiB; individual SSE frame: 4 MiB.
- At most 128 tool calls; 1 MiB arguments per tracked tool; total tracked input is
  also constrained by the 8 MiB stream budget.
- At most four request processes, a four-connection listening backlog, and
  30-second socket idle timeout. Over-capacity accepted connections are closed.
- 360-second accepted-connection wall deadline, including headers/body/refresh.
- 180-second inference budget begins only after refresh; the total connection
  deadline still caps it. Worker alarms and an independent supervising process
  terminate blocked requests, including refresh, DNS, upstream, and consumer I/O.
  Parent deadline polling is 50 ms, subject to normal OS scheduling latency.

The supervisor kills workers, not merely sockets. If refresh is interrupted after
its POST, the helper's durable in-flight marker survives; the released lock can be
reacquired but another rotation is refused. Never delete that marker to retry.

Only validated `response.completed` is success. Downstream uses HTTP chunked
framing. Normal wall deadlines attempt one nonblocking fixed error frame and then
exit immediately; the actual binary fails with one ingress/one upstream request.
A blocked/partially-written downstream stream, forced SIGKILL, or failed error send
instead leaves an incomplete chunked body. ZeroClaw may then attempt its internal
`stream=false` fallback even with `provider_retries=0`; the adapter rejects that
request before credential access/upstream, preventing inference replay. Do not
claim one ingress for every forced-kill/blocked-consumer case. The initial raw-EOF
implementation reproduced false success and was rejected by a failing real-binary
test before this framing fix.

These are bounded transport budgets, not a tokenizer or an account capacity
promise. 32 MiB accommodates many large text requests but does not guarantee every
872000-token payload, multimodal encoding, output, or runtime memory pattern.

## Approved empty-output compatibility contract

A user-approved exception accepts `response.completed` with `status=completed`
and an explicitly present `output: []` after tool streaming only when every
announced call has a separate, validated `response.output_item.done`. The
arguments-done event alone is insufficient. Missing/null output with tracked
calls, nonempty partial sets, identity/argument/type/index contradictions,
duplicate call IDs, and reported non-completed final item statuses fail closed.
Final item identity fields must be explicit. Response IDs and output indexes are
checked for consistency when supplied; absent optional metadata is not invented.
No events are rewritten and no history or terminal completion is synthesized.
The existing text-only handling of absent output is unchanged.

This deliberately drops the old requirement for terminal re-enumeration when
output is explicitly empty. Observed SIWC wire behavior motivated it; OpenAI's
streaming reference documents item-done and response-completed separately, but
does not explicitly guarantee that an empty terminal output means omission.
Do not present this compatibility choice as that official guarantee.

`test_completion_contract.py` exercises the pure integrity rules (set
`ADAPTER_SOURCE` to select packaged source). `regression.py` retains all original
spike safety gates unchanged and adds `gate7_empty_completion.py` in a disposable
fixture tree. Original gate6's arguments-done-only omission case remains a
negative; the newly approved positive requires item-done. Gate7 checks byte-for-
byte forwarding, negative HTTP cases, and the actual retained ARM client's
reasoning + calculator/call-ID roundtrip with empty completion output. Historical
spike fixtures and result evidence are not modified. `ADAPTER_SOURCE` also selects
the source for runtime and real-binary deadline tests.

Primary reference: https://developers.openai.com/api/reference/resources/responses/streaming-events

## Model configuration and retained binary

The configured model is exactly `gpt-5.6-sol`. Provider `context_window=872000`,
runtime `max_context_tokens=872000`, and `context_compact_ratio=0.9` resolve to a
784800-token proactive trimming threshold. `history_pruning.enabled=false` avoids
its smaller independent cap. `context_compression.enabled=false` avoids the
removed runtime compressor. `provider_retries=0`; no fallback providers or native
OAuth profiles are configured. Config read-back with the retained binary verifies
these inputs, not full-context provider entitlement or observed capacity.

`packages/zeroclaw-pinned.nix` reuses the exact retained upstream full-feature
v0.8.6 derivation/output:

- `/nix/store/r4k0xpgaa1fl2bxnf634dr65zccxg9z3-zeroclaw-0.8.6.drv`
- `/nix/store/adkc7f6i4b46gaf1296ir59whcjva4cl-zeroclaw-0.8.6`

Source revision: `c473221313341a853e04122f93bb9bd26b5e6c47`; upstream
`packages.aarch64-linux.zeroclaw`, its locked nixpkgs/fenix and default feature set.
No new flake input, lock update, or Rust build is introduced. These store paths
must be retained on the evaluator; missing paths intentionally fail evaluation.
Transfer the retained runtime closure before a remote build if needed; do not
replace it with a different nixpkgs ZeroClaw or start another source build.

## Offline acceptance commands

From the repository root, using the already retained Python environment:

```sh
PY=/nix/store/cy3l2yl4r4sjspgnb9n0jg2799j4zja6-python3-3.13.15-env/bin/python3
unshare -Urn sh -c 'ip link set lo up; exec "$0" -B tests/siwc-adapter/test_runtime.py -v' "$PY"
unshare -Urn sh -c 'ip link set lo up; exec "$0" -B tests/siwc-adapter/test_binary_deadline.py -v' "$PY"
unshare --user --map-auto --map-root-user --net --mount sh -c 'ip link set lo up; exec python3 -B tests/siwc-adapter/binary_runtime.py'
unshare --user --map-auto --map-root-user --net sh -c 'ip link set lo up; exec python3 -B tests/siwc-adapter/test_provision.py -v'
unshare -Urn sh -c 'ip link set lo up; exec "$0" -B tests/siwc-adapter/regression.py "$1"' "$PY" /nix/store/ADAPTER-OUTPUT/lib/filtering_adapter.py
nix eval --offline --impure --json --file tests/pi4-siwc-adapter.nix
python3 -B tests/evaluate.py
nix eval --offline --impure --json --file tests/pi4-chatgpt-auth.nix
nix eval --offline --impure --json --file tests/zeroclaw-account.nix
```

`regression.py` executes gates 1/2/4/5/6/7 against the selected candidate source with
temporary test source/config copies and newly synthetic state. Historical fixtures
and result files remain untouched. Gate1's isolated legacy invocation selects its
historical 10-second idle/20-second stream budgets; the production CLI keeps its
explicit larger budgets. Completion failures, calculator result/call-ID roundtrip,
reasoning preservation, locking, auth, refresh ambiguity and secure CLI roundtrip
all remain acceptance gates.

## Live acceptance and operational boundary

The ARM adapter closure was copied to the Pi, and Colmena built and activated only
`pi4` with `--no-keys`; the existing ZeroClaw binary was reused without a Rust
rebuild. The active and boot-default system paths match. This does not substitute
for a reboot test.

Verified on the deployed host:

- Both listeners are loopback-only; the gateway health endpoint succeeds and
  pairing remains required. No external gateway pairing/client setup was performed.
- OAuth ownership and 0700/0600 modes remain unchanged. The separate agent UID
  cannot read the canonical credential file. The runtime capability was absent
  from agent persistent files during the post-restart scan.
- An expired access token was renewed by the actual hardened adapter request path;
  subsequent status was authenticated, unexpired, and without an ambiguous marker.
- Actual ARM client, under the running daemon's mount/network namespaces and
  separate agent UID, executed calculator `12345 * 6789` and returned
  `LIVE_TOOL_OK=83810205`. A successful calculator trace receipt and two provider
  requests in that turn establish the tool/result/follow-up path. The same probe
  passed after all lifecycle restart checks.
- The live CLI probe used a private temporary runtime installation with the same
  provisioned config. It did not use the daemon's paired HTTP/RPC chat interface.
  ZeroClaw refuses a second `agent` CLI sharing an installation already owned by
  its daemon; do not bypass that lock. Pair a client for normal daemon-backed use,
  or use a separately isolated installation for controlled acceptance.
- Restarting each of `pi4-zeroclaw`, `pi4-siwc-adapter`, and `pi4-siwc-runtime`
  restored health, restarted dependent agent processes, and preserved capability.
  The daily refresh timer remains enabled/active; no failed system units remain.
- Temporary observer code, decision log, runtime systemd override, and probe state
  were removed. Credentials and capability values were never printed.
- Final offline verification: six regression suites, nine completion-contract tests,
  fifteen runtime tests, two actual-binary deadline tests, two provisioning tests,
  ARM wrapper smoke and distinct-UID daemon startup. Historical spike evidence
  remains unchanged. Four exact VM derivations and original lock nodes are preserved;
  only the authorized Pi import changed among the 69 baseline files.

Coordinator evidence and bounded live-check scripts are retained outside the repo:
`../.swarm/siwc-live-evidence.json`, `../.swarm/live-probe.py`, and
`../.swarm/live-lifecycle.py`. The probe deliberately avoids printing raw config,
credentials, or full traces; it is not an operator chat frontend.
