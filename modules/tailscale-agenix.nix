{ config, pkgs, lib, ... }:

let
  cfg = config.custom.tailscale-agenix;
in {
  options.custom.tailscale-agenix = {
    enable = lib.mkEnableOption "Enable Tailscale with agenix secrets";
  };

  config = lib.mkIf cfg.enable {
    # Define the agenix secret for Tailscale
    age.secrets.tailscale-authkey = {
      file = ../tailscale-authkey.age;
      owner = "root";
      group = "root";
      mode = "600";
    };

    # Configure Tailscale to use the agenix secret
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "client";
      authKeyFile = config.age.secrets.tailscale-authkey.path;
    };
  };
}