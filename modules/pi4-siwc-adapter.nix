{ pkgs, ... }:
let
  adapter = import ../packages/siwc-adapter.nix { inherit pkgs; };
  ready = pkgs.writeText "pi4-siwc-ready.py" ''
    import socket, time
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', 18766), timeout=.2):
                raise SystemExit(0)
        except OSError:
            time.sleep(.05)
    raise SystemExit(1)
  '';
in {
  imports = [ ./pi4-zeroclaw.nix ];
  systemd.services.pi4-siwc-runtime = {
    description = "Provision runtime-only SIWC local capability";
    before = [ "pi4-siwc-adapter.service" "pi4-zeroclaw.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Group = "root";
      ExecStart = "${adapter}/bin/pi4-siwc-provision";
      RuntimeDirectory = "pi4-siwc";
      RuntimeDirectoryMode = "0711";
      RuntimeDirectoryPreserve = "yes";
      UMask = "0077";
      TimeoutStartSec = "15s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/run/pi4-siwc" ];
      PrivateNetwork = true;
      PrivateTmp = true;
      PrivateDevices = true;
      CapabilityBoundingSet = [ "CAP_CHOWN" "CAP_DAC_OVERRIDE" "CAP_FOWNER" ];
      MemoryMax = "128M";
      TasksMax = 8;
      LimitCORE = 0;
    };
  };
  systemd.services.pi4-siwc-adapter = {
    description = "Bounded loopback SIWC Responses adapter";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    requires = [ "pi4-siwc-runtime.service" ];
    after = [ "network-online.target" "pi4-siwc-runtime.service" ];
    bindsTo = [ "pi4-siwc-runtime.service" ];
    partOf = [ "pi4-siwc-runtime.service" ];
    unitConfig.Upholds = [ "pi4-zeroclaw.service" ];
    serviceConfig = {
      Type = "exec";
      User = "zeroclaw";
      Group = "zeroclaw";
      ExecStart = "${adapter}/bin/pi4-siwc-adapter --listen-port 18766 --state-dir /var/lib/zeroclaw/siwc-test-state --capability-file /run/pi4-siwc/adapter/capability --max-request-bytes 33554432 --max-frame-bytes 4194304 --max-stream-bytes 8388608 --max-connections 4 --request-seconds 360 --inference-seconds 180 --idle-seconds 30";
      ExecStartPost = "${adapter.python}/bin/python3 -I ${ready}";
      WorkingDirectory = "/var/lib/zeroclaw/siwc-test-state";
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "15s";
      TimeoutStopSec = "10s";
      KillMode = "control-group";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadOnlyPaths = [ "/run/pi4-siwc" ];
      ReadWritePaths = [ "/var/lib/zeroclaw/siwc-test-state" ];
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
      MemoryMax = "768M";
      TasksMax = 16;
      LimitNOFILE = 128;
      LimitCORE = 0;
      StandardOutput = "null";
      StandardError = "null";
    };
  };
}
