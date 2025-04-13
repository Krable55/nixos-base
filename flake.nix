{
  description = "NixOS system flake with image building and system config support";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }: {
    # VM image builder (e.g., for Proxmox)
    packages.x86_64-linux.default = nixos-generators.nixosGenerate {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];
      format = "proxmox";
    };

    # NixOS config for installation or configuration management
    nixosConfigurations."nixos-builder" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];
    };
  };
}
