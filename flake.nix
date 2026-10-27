{
  description = "NixOS system flake with image building and system config support";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    # Isolated Pi lifecycle: do not upgrade the existing fleet package set.
    nixpkgs-pi.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Pinned to the nixpkgs commit that bumped n8n to 2.33.7 (merged
    # 2026-08-09, PR NixOS/nixpkgs#550691) -- the main nixpkgs input above
    # only has 2.32.6 as of this writing. Used only to pull the n8n
    # package itself (see modules/n8n.nix); everything else stays on the
    # main pin.
    nixpkgs-n8n.url = "github:NixOS/nixpkgs/6d2c43d6d44ac102642231913e62272193393c98";

    colmena = {
      url   = "github:zhaofengli/colmena";
      flake = true;
    };

    sops-nix = {
      url = "sops-nix"; # Match the existing lock entry.
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

  in {
    # ARM build cost: aarch64-linux selects an ARM build platform, NOT automatic
    # x86 -> ARM cross-compilation. Local builds on our x86 workstation can run
    # ARM compilers under QEMU when no cached output is available. The standalone
    # upstream ZeroClaw v0.8.6 full-feature source build took ~3.5 hours this way.
    # This is NOT the cost of every package addition: cached packages download,
    # and unchanged store outputs are reused while retained (or substitutable).
    # Service/user/credential changes alone do not rebuild the application;
    # version, feature, source or toolchain changes can require a new build.
    # Before another large uncached ARM build, prefer a native ARM builder,
    # validate a real cross-build, or consider a hash-pinned upstream binary.
    # Colmena's Pi buildOnTarget=true below instead builds natively on the Pi;
    # the slow ZeroClaw experiment was a separate local `nix build` invocation.
    #
    # Explicit ARM image output: independent of the legacy VM generator outputs.
    nixosConfigurations.pi4-image = inputs.nixpkgs-pi.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit inputs outputs; };
      modules = [ ./hosts/pi4.nix ./images/pi4.nix ];
    };
    packages.aarch64-linux.pi4-image =
      self.nixosConfigurations.pi4-image.config.system.build.sdImage;
    # Export nixosModules as a flake output
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
      lore            = import ./modules/lore.nix;
      zitadel         = import ./modules/zitadel.nix;
      oauth2-proxy    = import ./modules/oauth2-proxy.nix;
    };

    # For VM image building (e.g., `nix build`)
    packages.${system}.default = nixos-generators.nixosGenerate {
      inherit system;
      specialArgs = { inherit inputs outputs; };
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

    # overlays = import ./overlays {inherit inputs;};


    # System config for use with `nixos-rebuild`
    nixosConfigurations."nixos-builder" = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs outputs; };
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

   colmenaHive = colmena.lib.makeHive {
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
        imports = [ ./hosts/pi4.nix ./modules/pi4-secrets.nix ./modules/pi4-chatgpt-auth.nix ./modules/pi4-siwc-adapter.nix ];
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

      auth = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.125";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "auth" ];
        };
        imports = [ ./base.nix ./hosts/auth.nix ];
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

      trader = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.86";
          targetUser    = "root";
          buildOnTarget = true;
          tags = [ "trader" ];
        };
        imports = [ ./base.nix ./hosts/trader.nix ];
      };

      lore = { config, pkgs, lib, ... }: {
        deployment = {
          targetHost    = "192.168.50.36";
          targetUser    = "root";
          buildOnTarget = true;
          tags          = [ "lore" ];
        };
        imports = [ ./base.nix ./hosts/lore.nix ];
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
