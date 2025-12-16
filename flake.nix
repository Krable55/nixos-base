{
  description = "NixOS system flake with image building and system config support";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    colmena = {
      url   = "github:zhaofengli/colmena";
      flake = true;
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, sops-nix, agenix, colmena, ... }@inputs: let
  inherit (self) outputs;
  system = "x86_64-linux";
  
  # Support multiple systems for development
  supportedSystems = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ];
  forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

  nixosModules = {
    default         = import ./configuration.nix;
    media           = import ./modules/media.nix;
    forgejo         = import ./modules/forgejo.nix;
    colmena         = import ./modules/colmena.nix;
    nfs             = import ./modules/nfs.nix;
    backup          = import ./modules/backup.nix;
    n8n             = import ./modules/n8n.nix;
    supabase        = import ./modules/supabase.nix;
    claude          = import ./modules/claude-code.nix;
    agenix          = import ./modules/agenix.nix;
    agenix-test     = import ./modules/agenix-test.nix;
    tailscale-agenix = import ./modules/tailscale-agenix.nix;
    k3s             = import ./modules/k3s.nix;
    nuclio          = import ./modules/nuclio;
    nuclio-functions = import ./modules/nuclio/functions.nix;
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
        self.nixosModules.agenix
        self.nixosModules.tailscale-agenix
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
        self.nixosModules.agenix
        self.nixosModules.tailscale-agenix
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
      
      trader = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.86";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "trader" ];
        };
        imports = [ ./hosts/trader.nix ];
      };
    };

    # Development shell with agenix and colmena for all supported systems
    devShells = forAllSystems (system: {
      default = nixpkgs.legacyPackages.${system}.mkShell {
        buildInputs = with nixpkgs.legacyPackages.${system}; [
          agenix.packages.${system}.default
          colmena.packages.${system}.colmena
          git
          age
          openssh
        ];
        
        shellHook = ''
          echo "🔑 Development shell loaded!"
          echo "Available commands: agenix, colmena, git, age, ssh"
          echo ""
          echo "Quick commands:"
          echo "  colmena apply --on media-center"
          echo "  agenix -e secret.age"
        '';
      };
    });
  };
}
