{ config, pkgs, lib, ... }:

let
  cfg = config.custom.claude-code;
in {
  options.custom.claude-code = {
    enable = lib.mkEnableOption "Enable Claude Code CLI";
    nodeVersion = lib.mkOption {
      type = lib.types.str;
      default = "nodejs_22";
      description = "Node.js version to use (nodejs_18, nodejs_20, nodejs_22)";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.config.allowUnfree = true;
    # Install Node.js and Claude Code CLI
    environment.systemPackages = with pkgs; [
      pkgs.${cfg.nodeVersion}
      nodePackages.npm
      claude-code
    ];
  };
}