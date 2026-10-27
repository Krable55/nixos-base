{ config, pkgs, lib, inputs, ... }:

{
  imports = [ inputs.agenix.nixosModules.default ];

  # Install agenix CLI tool
  environment.systemPackages = [ inputs.agenix.packages.${pkgs.system}.default ];

  # Use SSH host key for agenix decryption
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
}