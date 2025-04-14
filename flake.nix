{
  description = "NixOS system flake with image building and system config support";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      flake = true;
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, sops-nix, ... }@inputs: let
    system = "x86_64-linux";
  in {
    # For VM image building (e.g., `nix build`)
    packages.${system}.default = nixos-generators.nixosGenerate {
      inherit system;
      modules = [
        self.nixosModules.default
        self.nixosModules.forgejo
        self.nixosModules.media
        sops-nix.nixosModules.sops
      ];
      format = "proxmox";
    };

    # System config for use with `nixos-rebuild`
    nixosConfigurations."nixos-builder" = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        self.nixosModules.forgejo
        self.nixosModules.media
        sops-nix.nixosModules.sops
      ];
    };

    # Export reusable modules
    nixosModules = {
      default   = import ./configuration.nix;
      media   = import ./modules/media.nix;
      forgejo   = import ./modules/forgejo.nix;
    };
  };
}
