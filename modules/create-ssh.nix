{ config, pkgs, lib, ... }:

let
  cfg = config.custom.create-ssh;
  user = "kyle";  # Specify the username
  sshKeyPath = "/home/${user}/.ssh/id_ed25519";  # Adjust the path as necessary
in
{
  options.custom.create-ssh = {
    enable = lib.mkEnableOption "Enbable the creation of an shh key";
    
    group = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "ssh";
      description = "Optional group for the user. If null, defaults to 'ssh'.";
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "kyle";
      description = "Optional user. If null, defaults to 'kyle'.";
    };
  };


  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.openssh ];

    # Configuration for the user
    users.users = lib.optionalAttrs (cfg.user != "kyle") {
      "${cfg.user}" = {
        isNormalUser = true;
        home = "/home/${cfg.user}";
        createHome = true;
        group = cfg.group;
      };
    };

    # Only create the group if it's not the default 'users' group
    users.groups = {
      ${cfg.group} = {
        members = [cfg.user];
      };
    };

    systemd.services.generate-ssh-key = {
      wantedBy = [ "multi-user.target" ];
      before = [ "network.target" ];
      path = [ pkgs.openssh ];
      script = ''
        # Ensure SSH directory is properly set up
        if [ ! -f ${sshKeyPath} ]; then
          mkdir -p /home/${cfg.user}/.ssh
          chown ${cfg.user}:${cfg.group} /home/${cfg.user}/.ssh
          chmod 700 /home/${cfg.user}/.ssh
          ssh-keygen -t ed25519 -f ${sshKeyPath} -N ""
        fi
      '';
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
    };
  };
}
