# nixos-base
NixOS flakes and configurations for Proxmox VMs and Colmena deployments.

### Update flake and rebuild (from VM)
1. `sudo nix flake update`
2. `sudo nixos-rebuild switch --flake .#nixos-builder`

## Colmena

## Apply configs on all machines:
`colmena apply --impure`

## Apply to single machine using tags:
`colmena apply --impure --on @builder`
## Apply to multiple machine using tags:
`colmena apply --impure --on '@infra-*'`


### [Deploy secrets](https://colmena.cli.rs/unstable/features/keys.html)

# Networking
1. Create an empty WireGuard  config file here: 

2. You can get a valid server config for nord VPN using [this website](https://nord-configs.onrender.com/),

3. Follow the steps mentioned in `wireguard_helper.sh` to run the script and retrieve your NordLynx Private Key. Include this in the 

```
sudo ip route add 193.29.61.8 via 192.168.50.1 dev ens18
```
