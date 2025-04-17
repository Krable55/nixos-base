{
  description = "Extended NixOS Config for Media center";

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
        base.nixosModules.backup
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
            backups = {
              device = "192.168.50.154:/Backups";
              owner = "media";
              group = "media";
              mode = "0775";
            };
          };

          custom.backup = {
            enable = true;
            srcDir = "/var/lib";
            includePaths = [ "sonarr" "radarr" "readarr" "lidarr" "prowlarr" "plexpy" ];
            targetDir = "/mnt/backups/media-center-data";
            interval = "daily";
            retention = {
              daily = 5;
              weekly = 3;
              monthly = 6;
            };
          };
        })
      ];
    };
  };
}