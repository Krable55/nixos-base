{ pkgs, lib, ... }:
let
  herdr = pkgs.callPackage ../packages/herdr.nix { };
in {
  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "none";
    # Enroll interactively; never embed a tailnet auth key in Git/the Nix store.
    authKeyFile = null;
  };

  environment.systemPackages = [ herdr ];
  users.users.kyle.linger = true;

  systemd.user.services.herdr = {
    description = "Persistent Herdr default session";
    wantedBy = [ "default.target" ];
    # This user unit is installed globally, but only kyle owns this session.
    unitConfig.ConditionUser = "kyle";
    environment = {
      PATH = lib.mkForce "/run/wrappers/bin:/etc/profiles/per-user/kyle/bin:/run/current-system/sw/bin";
      SHELL = "${pkgs.bashInteractive}/bin/bash";
    };
    serviceConfig = {
      ExecStart = "${herdr}/bin/herdr --session default server";
      WorkingDirectory = "%h";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
