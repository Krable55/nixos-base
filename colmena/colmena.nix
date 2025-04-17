{
  description = "Extended NixOS Config with Forgejo + Colmena";

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
        base.nixosModules.colmena
        base.nixosModules.forgejo
        base.nixosModules.backup
        base.nixosModules.nfs
        ({ ... }: {
          custom.colmena.enable = true;
          custom.forgejo.enable = true;
          
          custom.nfs.enable = true;
          custom.nfs.mounts = {
            backups = {
              device = "192.168.50.154:/Backups";
              owner = "media";
              group = "media";
              mode = "0775";
            };
          };

          custom.backup = {
            enable = true;
            interval = "daily"; # or "weekly", or "Mon *-*-* 01:00:00"
          };
        })
      ];
    };
  };
}