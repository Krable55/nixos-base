# nixos-base
NixOS flakes and configurations for Proxmox VMs and Colmena deployments.

## Raspberry Pi 4

See [Pi4 image, evaluation, deployment and recovery](docs/pi4.md). The Pi uses a
separate stable package pin; existing VM pins are unchanged. Use only the named
Pi image output and Pi-scoped Colmena commands for this workflow. A local image
build does not authorize flashing or deployment.

## Quick Start

### Update flake and rebuild (from VM)
1. `sudo nix flake update`
2. `sudo nixos-rebuild switch --flake .#nixos-builder`

## Colmena
`nix-shell -p colmena`

## Apply configs on all machines:
`colmena apply --impure`

## Apply to single machine using tags:
`colmena apply --impure --on @builder`
## Apply to multiple machine using tags:
`colmena apply --impure --on '@infra-*'`


## Managing Secrets with Agenix

This repository uses [agenix](https://github.com/ryantm/agenix) for encrypting secrets. Secrets are encrypted with age and can only be decrypted by authorized hosts.

### Prerequisites
Ensure you're in the nix environment with agenix available:
```bash
nix-shell -p agenix
```

### Adding a Single Secret

Use the `add-secret.sh` script to add individual secrets:

```bash
# Interactive mode (will prompt for secret value)
./scripts/add-secret.sh secrets/media-center/kometa/plex-token.age

# Non-interactive mode (pass value as argument)
./scripts/add-secret.sh secrets/media-center/kometa/plex-token.age "your-secret-value"
```

### Adding Multiple Secrets for a Service

Use the `add-service-secrets.sh` script to add multiple secrets at once:

```bash
# Add all secrets for a service in one command
./scripts/add-service-secrets.sh media-center kometa \
  plex-token="rqyWME8LpHPoNwLnFyAG" \
  mdblist-apikey="k0s90j8w4v19sjd3q5zvytl6d" \
  tmdb-apikey="3ba96efb12fe2aafa920f84d4500dfbe"
```

### Complete Workflow for Adding Secrets

1. **Create encrypted secret files** (using scripts above)

2. **Define secrets in `secrets.nix`**:
   ```nix
   (mkServiceSecrets "media-center" media-center "kometa" [
     "plex-token"
     "mdblist-apikey"
     "tmdb-apikey"
   ])
   ```

3. **Reference secrets in host config** (e.g., `hosts/media-center.nix`):
   ```nix
   age.secrets.kometa-plex-token = {
     file = ../secrets/media-center/kometa/plex-token.age;
     owner = "kometa";
     group = "media";
     mode = "400";
   };
   ```

4. **Use secrets in module config** (e.g., `modules/kometa/kometa.nix`):
   ```nix
   # Read secret at runtime
   PLEX_TOKEN=$(cat ${config.age.secrets.kometa-plex-token.path})
   ```

5. **Deploy**:
   ```bash
   nixos-rebuild switch --flake .#media-center
   ```

### Editing Existing Secrets

To edit an existing secret:
# Edit
```
agenix -i ~/.ssh/id_ed25519 secrets/media-center/kometa/plex-token.age
```

```bash
agenix -e secrets/media-center/kometa/plex-token.age
```

### Viewing Secret Definitions

Check which hosts can decrypt which secrets:
```bash
cat secrets.nix
```

### [Deploy secrets with Colmena](https://colmena.cli.rs/unstable/features/keys.html)

## Networking
1. Create an empty WireGuard  config file here: `/etc/wireguard/wg0.conf`
 > You can get a valid server config for nord VPN using [this website](https://nord-configs.onrender.com/),

3. Follow the steps mentioned in `wireguard_helper.sh` to run the script and retrieve your NordLynx Private Key. Include this in the
`wg0.conf` file.

```
sudo ip route add 193.29.61.8 via 192.168.50.1 dev ens18
```
