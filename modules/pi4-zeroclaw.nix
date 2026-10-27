# Pi-only account and daemon. The credential owner remains the original zeroclaw.
{ pkgs, ... }:
let
  zeroclaw = import ../packages/zeroclaw-pinned.nix;
  siwcAdapter = import ../packages/siwc-adapter.nix { inherit pkgs; };
  pairingRuntimeConfig = "/run/zeroclaw-agent/config.toml";
  pairingStore = "/var/lib/zeroclaw-agent/gateway-pairing.json";
  pairingReady = "/run/zeroclaw-agent/pairing-merge-ok";
  pairingState = "${siwcAdapter}/bin/pi4-zeroclaw-pairing-state";
  snapshotPairing = pkgs.writeShellScript "pi4-zeroclaw-pairing-snapshot" ''
    set -eu
    if test -f ${pairingReady}; then
      exec ${pairingState} snapshot \
        --runtime-config ${pairingRuntimeConfig} \
        --canonical-config /run/pi4-siwc/agent/config.toml \
        --store ${pairingStore}
    fi
  '';
  launch = pkgs.writeShellScript "pi4-zeroclaw-launch" ''
    exec ${pkgs.coreutils}/bin/env -i \
      HOME=/var/lib/zeroclaw-agent \
      PATH=/run/current-system/sw/bin LANG=C.UTF-8 \
      SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
      ${zeroclaw}/bin/zeroclaw --config-dir /run/zeroclaw-agent \
      --log-level error daemon --host 127.0.0.1 --port 42617
  '';
in {
  users.groups.zeroclaw-agent = {};
  users.users.zeroclaw-agent = {
    isSystemUser = true;
    group = "zeroclaw-agent";
    extraGroups = [];
    home = "/var/lib/zeroclaw-agent";
    createHome = true;
    homeMode = "0700";
    shell = "${pkgs.shadow}/bin/nologin";
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [];
    linger = false;
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/zeroclaw-agent 0700 zeroclaw-agent zeroclaw-agent -"
    "d /var/lib/zeroclaw-agent/data 0700 zeroclaw-agent zeroclaw-agent -"
    "d /var/lib/zeroclaw-agent/shared 0700 zeroclaw-agent zeroclaw-agent -"
    "d /var/lib/zeroclaw-agent/agents 0700 zeroclaw-agent zeroclaw-agent -"
  ];
  systemd.services.pi4-zeroclaw = {
    description = "ZeroClaw with private SIWC capability (loopback only)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "pi4-siwc-runtime.service" "pi4-siwc-adapter.service" ];
    after = [ "pi4-siwc-runtime.service" "pi4-siwc-adapter.service" ];
    bindsTo = [ "pi4-siwc-runtime.service" "pi4-siwc-adapter.service" ];
    partOf = [ "pi4-siwc-runtime.service" "pi4-siwc-adapter.service" ];
    serviceConfig = {
      Type = "exec";
      User = "zeroclaw-agent";
      Group = "zeroclaw-agent";
      RuntimeDirectory = "zeroclaw-agent";
      RuntimeDirectoryMode = "0700";
      ExecStartPre = pkgs.writeShellScript "pi4-zeroclaw-runtime-config" ''
        set -eu
        ${pkgs.coreutils}/bin/rm -f ${pairingReady}
        test ! -e /run/zeroclaw-agent/auth-profiles.json
        for part in data shared agents; do
          ${pkgs.coreutils}/bin/ln -sfnT "/var/lib/zeroclaw-agent/$part" "/run/zeroclaw-agent/$part"
        done
        ${pkgs.coreutils}/bin/install -m 0600 /run/pi4-siwc/agent/config.toml /run/zeroclaw-agent/config.toml
        ${pairingState} merge \
          --runtime-config ${pairingRuntimeConfig} \
          --canonical-config /run/pi4-siwc/agent/config.toml \
          --store ${pairingStore}
        ${pkgs.coreutils}/bin/touch ${pairingReady}
      '';
      ExecStart = launch;
      ExecStopPost = snapshotPairing;
      WorkingDirectory = "/var/lib/zeroclaw-agent";
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStopSec = "15s";
      KillMode = "control-group";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      InaccessiblePaths = [ "/var/lib/zeroclaw" ];
      ReadOnlyPaths = [ "/run/pi4-siwc" ];
      ReadWritePaths = [ "/var/lib/zeroclaw-agent" "/run/zeroclaw-agent" ];
      ProtectProc = "invisible";
      ProcSubset = "pid";
      PrivateTmp = true;
      PrivateDevices = true;
      CapabilityBoundingSet = [];
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      RestrictSUIDSGID = true;
      LockPersonality = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      MemoryMax = "1G";
      TasksMax = 128;
      LimitNOFILE = 1024;
      LimitCORE = 0;
      # Pairing codes and generated runtime output must not enter the journal.
      StandardOutput = "null";
      StandardError = "null";
    };
  };

  # Start the watcher only after the daemon reached active state, so the fresh
  # template install and persisted-state merge cannot snapshot an intermediate
  # unpaired config. Reverse stop ordering stops the watcher before the daemon;
  # ExecStopPost performs the final graceful-stop flush.
  systemd.paths.pi4-zeroclaw-pairing-state = {
    description = "Watch ZeroClaw native pairing state";
    wantedBy = [ "multi-user.target" ];
    requires = [ "pi4-zeroclaw.service" ];
    after = [ "pi4-zeroclaw.service" ];
    partOf = [ "pi4-zeroclaw.service" ];
    # A path unit implicitly starts Before=paths.target. That early-boot edge
    # cycles with the daemon's network-online dependency, so replace only the
    # implicit defaults while retaining explicit daemon ordering and normal
    # shutdown semantics.
    unitConfig = {
      DefaultDependencies = false;
      Conflicts = "shutdown.target";
      Before = "shutdown.target";
    };
    pathConfig = {
      PathChanged = pairingRuntimeConfig;
      Unit = "pi4-zeroclaw-pairing-state.service";
    };
  };

  systemd.services.pi4-zeroclaw-pairing-state = {
    description = "Persist validated ZeroClaw paired-token hashes";
    requires = [ "pi4-zeroclaw.service" ];
    after = [ "pi4-zeroclaw.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "zeroclaw-agent";
      Group = "zeroclaw-agent";
      ExecStart = snapshotPairing;
      UMask = "0077";
      RuntimeMaxSec = "10s";
      TimeoutStartSec = "10s";
      TimeoutStopSec = "10s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      InaccessiblePaths = [ "/var/lib/zeroclaw" ];
      ReadWritePaths = [ "/var/lib/zeroclaw-agent" "/run/zeroclaw-agent" ];
      ProtectProc = "invisible";
      ProcSubset = "pid";
      PrivateTmp = true;
      PrivateDevices = true;
      CapabilityBoundingSet = [];
      RestrictAddressFamilies = [ "AF_UNIX" ];
      RestrictSUIDSGID = true;
      LockPersonality = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      MemoryMax = "128M";
      TasksMax = 16;
      LimitNOFILE = 64;
      LimitCORE = 0;
      StandardOutput = "null";
      StandardError = "null";
    };
  };
}
