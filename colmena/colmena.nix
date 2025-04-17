{
  description = "My NixOS fleet managed by Colmena";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    colmena.url = "github:zhaofengli/colmena";
  };

  outputs = { self, nixpkgs, colmena, ... }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in {
    nixosConfigurations = {
      media = import ../hosts/media-center.nix;
    };

    colmena = {
      meta = {
        nixpkgs = nixpkgs;
      };

      nodes = {
        media = { imports = [ ../hosts/media-center.nix ]; };  
      };
    };
  };
}
