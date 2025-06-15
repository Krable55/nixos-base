{ config, pkgs, lib, inputs, ... }:

let
  cfg = config.custom.sops-secrets;
in
{
  options.custom.create-ssh = {};

  imports = [ inputs.sops-nix.nixosModules.sops ];

  environment.systemPackages = with pkgs; [ git age ];
  
  sops = {
      sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
      age.keyFile = "/var/lib/sops-nix/key.txt";
      generateKey = true;
    };
}
