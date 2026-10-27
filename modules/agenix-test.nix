{ config, pkgs, lib, ... }:

let
  cfg = config.custom.agenix-test;
in {
  options.custom.agenix-test = {
    enable = lib.mkEnableOption "Enable agenix testing";
  };

  config = lib.mkIf cfg.enable {
    # Define agenix secrets
    age.secrets.test-secret = {
      file = ../test-secret.age;
      owner = "root";
      group = "root";
      mode = "600";
    };

    # Test service that uses the secret
    systemd.services.agenix-test = {
      description = "Test agenix secret access";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "test-agenix" ''
          echo "Testing agenix secret access..."
          if [ -f ${config.age.secrets.test-secret.path} ]; then
            echo "✅ Secret file exists at: ${config.age.secrets.test-secret.path}"
            echo "✅ Secret content preview: $(head -c 20 ${config.age.secrets.test-secret.path})..."
          else
            echo "❌ Secret file not found!"
            exit 1
          fi
        '';
      };
    };
  };
}