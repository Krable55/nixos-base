{
  description = "NixOS system flake with image building and system config support";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

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
      };

      # “defaults” get merged into every node’s config
      defaults = import ./base.nix;

      media-center = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.64";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "media-center" "media" "infra-media" ];
        };
        imports = [ ./hosts/media-center.nix ];
      };

      builder = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.243";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "builder" "infra-builder" ];
        };
        imports = [ ./hosts/builder.nix ];
      };

      networking = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.69";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "network" "networking" "infra-networking" ];
        };
        imports = [ ./hosts/networking.nix ];
      };

      powerball = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.119";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "powerball" ];
        };
        imports = [ ./hosts/powerball.nix ];
      };
    };
  };
}
