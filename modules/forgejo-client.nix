{ config, pkgs, lib, ... }:
let
  cfg = config.custom.forgejo-client;
  user = "kyle";  # Specify the username
  sshKeyPath = "/home/${user}/.ssh/id_ed25519.pub";
in {
  options.custom.forgejo-client = {
    enable = lib.mkEnableOption "Enable Forgejo Git client configuration";

    host = lib.mkOption {
      type        = lib.types.str;
      default     = "192.168.50.243";
      description = "The Forgejo host (e.g., git.example.com)";
    };

    user = lib.mkOption {
      type        = lib.types.str;
      default     = user;
      description = "SSH user for Git access (usually 'git')";
    };

    sshKeyFile = lib.mkOption {
      type        = lib.types.path;
      default     = sshKeyPath;
      description = "Path to the private SSH key for accessing Forgejo";
    };

    hostKey = lib.mkOption {
      type        = lib.types.str;
      default     = "${cfg.host} ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKGBOr+16aLDiNF5sRQmTZ9AsHmnE9tVF1k8Qul6w3ho";
      description = "The Forgejo server's SSH host key in known_hosts format";
    };
  };

  config = lib.mkIf cfg.enable {
    # Drop the private key into /etc/ssh/
    environment.etc."ssh/forgejo_id_rsa" = {
      source = cfg.sshKeyFile;
      user   = "root";
      group  = "root";
      mode   = "0400";
    };

    # Configure global SSH config for Forgejo
    environment.etc."ssh/ssh_config.d/forgejo.conf" = {
      text = ''
          Host ${cfg.host}
          User ${cfg.user}
          IdentityFile /etc/ssh/forgejo_id_rsa
          StrictHostKeyChecking yes
          UserKnownHostsFile /etc/ssh/ssh_known_hosts
        '';
      mode = "0644";
    };

    # Add Forgejo host key
    environment.etc."ssh/ssh_known_hosts" = {
      text = cfg.hostKey;
      mode = "0644";
    };
  };
}
