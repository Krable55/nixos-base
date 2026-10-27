# Runtime-only maintenance of the existing Pi-owned ChatGPT OAuth registration.
# State is never copied into Git or the Nix store; the historical path avoids
# duplicating a live rotating token during migration from the feasibility test.
{ pkgs, ... }:
let
  auth = import ../packages/chatgpt-auth.nix { inherit pkgs; };
  stateDir = "/var/lib/zeroclaw/siwc-test-state";
in {
  environment.systemPackages = [ auth ];
  systemd.tmpfiles.rules = [ "d ${stateDir} 0700 zeroclaw zeroclaw -" ];

  systemd.services.pi4-chatgpt-auth-refresh = {
    description = "Refresh the Pi-owned ChatGPT renewable session";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "zeroclaw";
      Group = "zeroclaw";
      ExecStart = "${auth}/bin/pi4-chatgpt-auth refresh";
      WorkingDirectory = stateDir;
      UMask = "0077";
      TimeoutStartSec = "5min";
      Restart = "no"; # Helper retries only classified, safe transient failures.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ stateDir ];
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
      MemoryMax = "256M";
      TasksMax = 32;
      LimitCORE = 0;
    };
  };

  systemd.timers.pi4-chatgpt-auth-refresh = {
    description = "Daily keepalive for the Pi-owned ChatGPT session";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "10min";
      AccuracySec = "1min";
      Unit = "pi4-chatgpt-auth-refresh.service";
    };
  };
}
