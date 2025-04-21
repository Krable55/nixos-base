# modules/cloudflared.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.cloudflared;
in
{
  ################################################################################
  # 1) Declare the options under `services.cloudflared`                          #
  ################################################################################
  options.custom.cloudflared = lib.mkEnableOption {
    type = lib.types.bool;
    default = false;
    description = "Enable a Cloudflare Tunnel via cloudflared";
  };

  options.custom.cloudflared.name = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "The name of the Cloudflare tunnel (as created in Cloudflare)";
  };

  options.custom.cloudflared.credentialsFile = lib.mkOption {
    type = lib.types.path;
    description = ''
      A JSON credentials file you downloaded from Cloudflare (e.g. 
      `tunnel credentials create …`).  This will be placed at
      `/etc/cloudflared/credentials.json`.
    '';
  };

  options.custom.cloudflared.configFile = lib.mkOption {
    type = lib.types.path;
    default = null;
    description = ''
      A YAML config file (with ingress rules, etc).  If provided it will be
      placed at `/etc/cloudflared/config.yml` and passed via
      `--config /etc/cloudflared/config.yml`.
    '';
  };

  options.custom.cloudflared.extraArgs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Any extra CLI args to append to `cloudflared tunnel run`";
  };


  ################################################################################
  # 2) Wire it all up when `enable = true`                                       #
  ################################################################################
  config = lib.mkIf cfg.enable {
    # install the binary
    environment.systemPackages = [ pkgs.cloudflare-cloudflared ];

    # drop the credentials & config into /etc/cloudflared/
    environment.etc."cloudflared/credentials.json" = {
      source = cfg.credentialsFile;
      user   = "root";
      group  = "root";
      mode   = "0600";
    };

    # only install config.yml if the user gave one
    # (else `--config` will be omitted)
    environment.etc."cloudflared/config.yml" = lib.mkIf (cfg.configFile != null) {
      source = cfg.configFile;
      user   = "root";
      group  = "root";
      mode   = "0644";
    };

    systemd.services.cloudflared = {
      description = "Cloudflare Tunnel";
      wants       = [ "network-online.target" ];
      after       = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " (
          [ "${pkgs.cloudflare-cloudflared}/bin/cloudflared"
            "tunnel"
            "run"
            cfg.name
          ]
          ++ lib.optional (cfg.configFile != null)
             [ "--config" "/etc/cloudflared/config.yml" ]
          ++ cfg.extraArgs
        );
        Restart = "on-failure";
        User    = "root";
      };

      wantedBy = [ "multi-user.target" ];
    };
  };
}
