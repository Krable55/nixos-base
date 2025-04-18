# nixos-base
NixOS base configuration

### Generate secret
1. Create age key
```
age-keygen -o colmena/secrets/age.key
```

2. Extract public key
```
age-keygen -y colmena/secrets/age.key > colmena/secrets/age.pub
```

3. Encrypt secrets
```
sops --encrypt --age "$(cat colmena/secrets/age.pub)" \
  --input-type yaml \
  --output colmena/secrets/secrets.yaml \
  colmena/secrets/secrets.dec.yaml
```

### Update flake and rebuild (from VM)
1. `sudo nix flake update`
2. `sudo nixos-rebuild switch --flake .#nixos-builder`

