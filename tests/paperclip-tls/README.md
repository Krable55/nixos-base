# Paperclip TLS renewal regression

Run from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/paperclip-tls -v
```

Requires Nix evaluation, Python 3, Bash, OpenSSL, flock and GNU coreutils.
The tests evaluate the actual module scripts, substitute a temporary state path
and the invoking user's ownership, and execute those scripts with real OpenSSL.
Systemctl is a recording/failure stub; generation failures and an interruption
immediately after publication are injected. Nothing accesses host services or
writes `/var/lib`. No deployment is performed.

Coverage: fresh provisioning, healthy/legacy preservation, 30-day renewal window,
missing/malformed/mismatched pairs, private-key permissions, failed generation,
invalid staged output, interrupted publication, consumer-refresh retry, timer
configuration and certificate-only container mount.

The implementation keeps boot provisioning separate from scheduled renewal to
avoid restarting dependants from their own prerequisite. A persistent daily timer
(with up to one hour jitter) checks the 365-day certificate. Publication switches
an atomic `current` symlink to a validated pair. Generation directories are 0750
root:nginx; keys are 0640; certificate files are 0644. The container mounts only
the certificate, never the directory/key.

Successful publication during renewal restarts both auto-start consumers:
recreating Paperclip refreshes the file-bind-mount inode and Node's startup-only
extra-CA trust; nginx reopens the matching pair. A generation-local marker keeps
refresh retryable after failure/interruption. `restart`, rather than `try-restart`,
is intentional so a failed/inactive consumer can recover on the next run. This
also means rotation starts either consumer if it was manually stopped. Healthy
checks without pending refresh do not restart anything. Renewal has a 35-minute
unit timeout (Paperclip already permits up to 30 minutes to start).

Old generations and any legacy flat pair are retained locally for diagnosis;
there is no automated garbage collection. Power-loss durability/fsync and live
systemd/container execution are not covered by these offline tests. A failed
refresh is retried at the next daily run, not immediately.

TDD evidence: the original script failed the near-expiry test before changes.
Subsequent RED/GREEN cycles caught in-place overwrite on generation failure,
malformed/mismatched keys, absent scheduling/refresh, unchecked staged output,
`try-restart` failing to recover an inactive consumer, and cleanup deleting an
already-published generation after SIGTERM. Final run: 10 tests passed.

A real `<nixpkgs/nixos>` module evaluation also succeeded: daily persistent timer,
non-remaining renewal oneshot, boot-only dependency ordering, and generated
`podman run --replace --rm` with only `current/server.crt` bound into the container.
This uses the local Nix channel, not the parent task's integrated remote flake;
full flake review/build and any live acceptance belong to the parent task.
