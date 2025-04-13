# nixos-base
NixOS base configuration

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
  secrets/secrets.yaml.dec
```

