# nixos-base
NixOS flakes and configurations for Proxmox VMs and Colmena deployments.

## Build a base VM template for proxmox

### Generate secret
1. Create age key
```
age-keygen -o secrets/age.key
```

2. Extract public key
```
age-keygen -y secrets/age.key > secrets/age.pub
```

3. Encrypt secrets
```
sops --encrypt --age "$(cat secrets/age.pub)" \
  --input-type yaml \
  --output secrets/secrets.yaml \
  secrets/secrets.dec.yaml
```

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

