{
  description = "Extended NixOS Config with Media center";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    base = {
      url = "github:Krable55/nixos-base";
      flake = true;
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      flake = true;
    };
  };

  outputs = { self, nixpkgs, base, sops-nix, ... }: {
    nixosConfigurations.nixos-builder = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        sops-nix.nixosModules.sops
        base.nixosModules.default
        base.nixosModules.media
        base.nixosModules.nfs
        ({ ... }: {
          custom.media.enable = true;

          custom.nfs.enable = true;
          custom.nfs.mounts = {
            media = {
              device = "192.168.50.154:/MediaCenter";
              owner = "media";
              group = "media";
              mode = "0775";
            };
            downloads = {
              device = "192.168.50.154:/Downloads";
            };
          };
       
        })
      ];
    };
  };
}