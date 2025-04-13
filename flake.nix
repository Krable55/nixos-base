{
  description = "Base NixOS image and system config";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }: {
    packages = {
      x86_64-linux = {
        default = nixos-generators.nixosGenerate {
          system = "x86_64-linux";
          modules = [
            ./configuration.nix
          ];
          format = "proxmox";
        };
      };
    };

    nixosConfigurations = {
      base = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
        ];
      };
    };
  };
}
