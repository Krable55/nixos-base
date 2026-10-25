{
  description = "NixOS system flake with image building and system config support";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    # Isolated Pi lifecycle: do not upgrade the existing fleet package set.
    nixpkgs-pi.url = "github:NixOS/nixpkgs/nixos-26.05";

    colmena = {
      url   = "github:zhaofengli/colmena";
      flake = true;
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      flake = true;
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, sops-nix, colmena, ... }@inputs: let
  inherit (self) outputs;
  system = "x86_64-linux";

  nixosModules = {
    default    = import ./configuration.nix;
    media      = import ./modules/media.nix;
    forgejo    = import ./modules/forgejo.nix;
    colmena    = import ./modules/colmena.nix;
    nfs        = import ./modules/nfs.nix;
    backup     = import ./modules/backup.nix;
    n8n        = import ./modules/n8n.nix;
    supabase   = import ./modules/supabase.nix;
    claude     = import ./modules/claude-code.nix;
  };
  in {
    # Explicit ARM image output: independent of the legacy VM generator outputs.
    nixosConfigurations.pi4-image = inputs.nixpkgs-pi.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit inputs outputs; };
      modules = [ ./hosts/pi4.nix ./images/pi4.nix ];
    };
    packages.aarch64-linux.pi4-image =
      self.nixosConfigurations.pi4-image.config.system.build.sdImage;

    # For VM image building (e.g., `nix build`)
    packages.${system}.default = nixos-generators.nixosGenerate {
      inherit system;
      modules = [
        self.nixosModules.media
        self.nixosModules.forgejo
        self.nixosModules.colmena
        sops-nix.nixosModules.sops
        self.nixosModules.nfs
        self.nixosModules.backup
        self.nixosModules.n8n
        self.nixosModules.supabase
        self.nixosModules.claude
        self.nixosModules.default
      ];
      format = "proxmox";
    };

    overlays = import ./overlays {inherit inputs;};

    # System config for use with `nixos-rebuild`
    nixosConfigurations."nixos-builder" = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.media
        self.nixosModules.forgejo
        self.nixosModules.colmena
        self.nixosModules.nfs
        sops-nix.nixosModules.sops
        self.nixosModules.backup
        self.nixosModules.n8n
        self.nixosModules.supabase
        self.nixosModules.claude
        self.nixosModules.default
      ];
    };

   colmena = {
      meta = {
        nixpkgs = import nixpkgs {
          system = "x86_64-linux";
        };
        specialArgs = {inherit inputs outputs;};
        nodeNixpkgs.pi4 = import inputs.nixpkgs-pi { system = "aarch64-linux"; };
      };

      # “defaults” get merged into every node’s config
      defaults = { imports = [ ./modules/common.nix ]; };

      pi4 = {
        imports = [ ./hosts/pi4.nix ];
        deployment = {
          targetHost = "pi4.local";
          targetUser = "kyle";
          privilegeEscalationCommand = [ "sudo" "-n" "-H" "--" ];
          buildOnTarget = true;
          tags = [ "pi4" ];
        };
      };

      media-center = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.64";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "media-center" "media" "infra-media" ];
        };
        imports = [ ./base.nix ./hosts/media-center.nix ];
      };

      builder = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.243";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "builder" "infra-builder" ];
        };
        imports = [ ./base.nix ./hosts/builder.nix ];
      };

      networking = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.69";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "network" "networking" "infra-networking" ];
        };
        imports = [ ./base.nix ./hosts/networking.nix ];
      };

      powerball = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.119";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "powerball" ];
        };
        imports = [ ./base.nix ./hosts/powerball.nix ];
      };
    };
  };
}
