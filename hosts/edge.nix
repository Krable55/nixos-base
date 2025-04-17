{ config, pkgs, lib, ... }:

{
  networking.hostName = "edge";
  deployment.targetHost = "edge.local";
  deployment.targetUser = "root";

  time.timeZone = "America/Los_Angeles";

  services.openssh.enable = true;

  # Enable Traefik with dynamic config directory
  imports = [ ../modules/traefik.nix ];
  services.traefik = {
    enable = true;
    dynamicConfigDir = "/etc/traefik/dynamic";
    logLevel = "INFO";
  };

  # Git + systemd-based dynamic config updates
  systemd.services.traefik-config-update = {
    description = "Update Traefik dynamic config from Forgejo repo";
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.git}/bin/git pull origin main";
      WorkingDirectory = "/etc/traefik/dynamic";
      User = "root";
      Environment = "GIT_SSH_COMMAND=ssh -i /root/.ssh/forgejo-traefik-key";
    };
  };

  systemd.timers.traefik-config-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /etc/traefik/dynamic 0755 root root -"
    "z /etc/traefik/dynamic 0700 root root -"
  ];

  nix.settings = {
    max-jobs = "auto";
    cores = 2;
    trusted-users = [ "root" ];
    experimental-features = [ "nix-command" "flakes" ];
  };

  users.users.kyle = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Add your SSH public key here
    ];
  };

  system.stateVersion = "24.05";
}
