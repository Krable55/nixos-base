{ config, pkgs, lib, ... }:

let
  cfg = config.custom.wgnord;
in {
  options.custom.wgnord = {
    enable     = lib.mkEnableOption "Enable Wireguard and NordVPN";
    scriptPath = lib.mkOption {
      type = lib.types.path;
      default = ./.bin/adjust-routing.sh;
      description = "Path to the rsync backup script file (e.g. ./.bin/rsync.sh).";
    };
  };

  config = lib.mkIf config.custom.wgnord.enable {
    networking.wireguard.enable = true;
    environment.systemPackages = [  
      pkgs.jql 
      pkgs.gawk
      pkgs.iproute2
      pkgs.dig
      pkgs.wireguard-tools
      pkgs.traceroute 
      pkgs.wireguard-ui
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/wireguard-ui 0755 root root -" # Creates directory with the right permissions
      "f /var/lib/wireguard-ui/.env 0644 root root -" # Creates an empty environment file if it does not exist
      "f /var/lib/wireguard-ui/wg0.conf 0600 root root -" # Creates an empty environment file if it does not exist
    ];

    systemd.services.wireguard-ui = {
      description = "WireGuard UI Daemon";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        description = "WireGuard UI Daemon";
        User = "root";
        Group = "root";
        Type = "simple";
        WorkingDirectory = "/var/lib/wireguard-ui"; # Updated working directory
        EnvironmentFile = "/var/lib/wireguard-ui/.env"; # Update if you have an environment file
        ExecStart = "${pkgs.wireguard-ui}/bin/wireguard-ui --bind-address '127.0.0.1:5000'"; 
        Restart = "always";
      };
      wantedBy = [ "multi-user.target" ];
  };
    
    networking.networkmanager.dns = "systemd-resolved";
    services.resolved.enable = true;

    systemd.services."restart-wg-quick-wg0" = {
      description = "Restart WireGuard on wg0.conf change";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl restart wg-quick@wg0.service";
        User = "root";
      };
      wantedBy = [ "multi-user.target" ]; # This line ensures the service is considered during system startup.
    };

  # Define the path unit to monitor changes
    systemd.services."wg-quick@wg0" = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "network-online.target" ];
      requires = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.wireguard-tools}/bin/wg-quick up /etc/wireguard/wg0.conf"; # copy /etc/wireguard/wg0.conf from nas/networking/wg-nord.conf
        ExecStop = "${pkgs.wireguard-tools}/bin/wg-quick down /etc/wireguard/wg0.conf";
        User = "root";
        Restart = "on-failure";
      };
    };

    systemd.paths.watch-wg0-conf = {
      description = "Watch /etc/wireguard/wg0.conf for changes";
      pathConfig.PathModified = "/etc/wireguard/wg0.conf";
      pathConfig.Unit = "restart-wg-quick-wg0.service";
      wantedBy = [ "multi-user.target" ];
    };

    networking.firewall.allowedUDPPorts = [ 51820 ];
  };
}
