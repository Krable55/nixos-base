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
    
    nixpkgs.overlays = [
      (final: prev: {
        claude-code = final.stdenv.mkDerivation {
          pname = "claude-code";
          version = "latest";
          
          nativeBuildInputs = [ final.nodejs_22 final.nodePackages.npm ];
          
          dontUnpack = true;
          dontBuild = true;
          
          installPhase = ''
            mkdir -p $out/bin
            cat > $out/bin/claude << 'EOF'
#!/bin/sh
exec ${final.nodejs_22}/bin/npx @anthropic-ai/claude-code "$@"
EOF
            chmod +x $out/bin/claude
          '';
          
          meta = with lib; {
            description = "Anthropic's official CLI for Claude";
            homepage = "https://github.com/anthropics/claude-code";
            license = licenses.mit;
            maintainers = [ ];
          };
        };
      })
    ];
    
    # Install Node.js and Claude Code CLI
    environment.systemPackages = with pkgs; [
      pkgs.${cfg.nodeVersion}
      nodePackages.npm
      claude-code
    ];
  };
}