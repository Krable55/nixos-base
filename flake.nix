{
  description = "NixOS system flake with image building and system config support";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }: let
    system = "x86_64-linux";
    baseModule = ./configuration.nix;
  in {
    # For VM image building (e.g., `nix build`)
    packages.${system}.default = nixos-generators.nixosGenerate {
      inherit system;
      modules = [ baseModule ];
      format = "proxmox";
    };

    # For use in nixos-rebuild (local only)
    nixosConfigurations."nixos-builder" = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ baseModule ];
    };

    # For reuse in other flakes
    nixosModules.default = baseModule;
  };
}
