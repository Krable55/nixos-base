{ config, pkgs, lib, ... }:

let
  cfg = config.custom.sopsProvider;
in {
  ################################################################################
  # 1) Option declarations                                                      #
  ################################################################################
  options.custom.sopsProvider = lib.mkIfEnabledOption {
    enable = lib.types.bool;
    rev    = lib.types.str;
    repo   = lib.types.str;
    # where to place the encrypted secrets.yaml
    defaultSopsFile  = lib.mkOption {
      type        = lib.types.str;
      default     = "/etc/sops/secrets.yaml";
      description = "Path where the encrypted SOPS YAML will be copied to";
    };
    # where to place your Age key, for sops‑nix to read
    ageKeyFilePath = lib.mkOption {
      type        = lib.types.str;
      default     = "/etc/sops/age.key";
      description = "Path where your Age private key is placed for decryption";
    };
  };

  ################################################################################
  # 2) Implementation when enabled                                              #
  ################################################################################
  config = lib.mkIf cfg.enable {
    # a) install git so we can fetch the repo
    environment.systemPackages = [ pkgs.git ];

    # b) systemd service + timer to fetch/pull your secrets repo
    systemd.services.fetchSecrets = {
      description = "Fetch SOPS secrets repo and install keys";
      wants       = [ "network-online.target" ];
      after       = [ "network-online.target" ];
      serviceConfig = {
        Type             = "oneshot";
        RemainAfterExit  = true;
        ExecStart        = lib.concatStringsSep " " [
          # clone if missing, else pull
          "if [ ! -d /var/lib/sops-secrets ]; then"
          "  git clone --depth 1 --branch" cfg.rev cfg.repo "/var/lib/sops-secrets"
          "else"
          "  (cd /var/lib/sops-secrets && git fetch origin" cfg.rev "&& git reset --hard origin/" cfg.rev ")"
          "fi"
          # ensure dest dir
          "mkdir -p $(dirname" cfg.ageKeyFilePath ")"
          # copy out the two files
          "cp /var/lib/sops-secrets/secrets.yaml" cfg.defaultSopsFile
          "cp /var/lib/sops-secrets/age.key"    cfg.ageKeyFilePath
        ];
        User = "root";
      };
      wantedBy = [ "multi-user.target" ];
    };

    # c) if you like, run it on every boot via a timer
    systemd.timers.fetchSecrets = {
      description = "Re‑fetch SOPS secrets every 10m";
      wantedBy   = [ "timers.target" ];
      timerConfig = {
        OnBootSec    = "1min";
        OnUnitActiveSec = "10min";
        Persistent   = true;
      };
      service = "fetchSecrets.service";
    };

    # d) make sure the target directories exist with safe perms
    systemd.tmpfiles.rules = [
      "d /etc/sops 0755 root root -"
      "z /etc/sops/*.key 0600 root root -"
      "z /etc/sops/*.yaml 0640 root root -"
    ];

    # e) wire up sops-nix
    imports = [ config.inputs.sops-nix.nixosModules.sops ];
    config.sops = {
      defaultSopsFile   = cfg.defaultSopsFile;
      defaultSopsFormat = "yaml";
      age.keyFile       = cfg.ageKeyFilePath;
    };
  };
}
