# SKILL: Replacing Hardcoded Secrets with Agenix in NixOS Modules

## Overview

This document describes the complete process for replacing hardcoded API keys, tokens, and other secrets in NixOS modules with encrypted agenix secrets. This skill is applicable to any NixOS configuration that uses agenix for secret management.

## When to Use This Skill

- You find hardcoded secrets (API keys, tokens, passwords) in configuration files
- You're adding a new service that requires sensitive credentials
- You want to improve security by encrypting secrets at rest
- You need to rotate secrets without exposing them in version control

## Prerequisites

1. **Agenix installed and configured** in the NixOS configuration
   - `inputs.agenix.nixosModules.default` imported
   - SSH host keys configured for decryption
   - `secrets.nix` file exists with host/user public keys

2. **Understanding of the target service**
   - How the service expects to receive secrets (env vars, config file, etc.)
   - Service documentation for environment variable support

3. **Access to the repository** with proper SSH keys for editing secrets

## Step-by-Step Process

### Phase 1: Discovery and Analysis

#### 1.1 Identify Hardcoded Secrets

Search the codebase for hardcoded sensitive values:
- API keys (e.g., `apikey: abc123xyz`)
- Authentication tokens (e.g., `token: secret_token`)
- Passwords
- Private keys
- Connection strings

**Example from kometa module:**
```yaml
# modules/kometa/config.yml
plex:
  token: sdkpsopomwr  # ❌ Hardcoded secret
mdblist:
  apikey: random123  # ❌ Hardcoded secret
tmdb:
  apikey: 0970979f860918we0980983we2wdf # ❌ Hardcoded secret
```

#### 1.2 Understand Service Configuration

Research how the service can consume secrets:
- **Environment variables**: Check if service supports env var substitution
- **Config file templating**: Some services support `${VAR}` or `<<VAR>>` syntax
- **Command-line arguments**: Secrets passed as CLI flags
- **Secret files**: Service reads from specific file paths

**Example - Kometa uses environment variables:**
- Supports `KOMETA_*` environment variables
- Uses `<<variablename>>` syntax in config files
- Variable names cannot contain underscores

#### 1.3 Check Existing Agenix Patterns

Look at other modules in the repository for patterns:
```bash
# Find existing agenix usage
grep -r "age.secrets" modules/
grep -r "mkServiceSecrets" secrets.nix
```

Common patterns to identify:
- How secrets are defined in `secrets.nix`
- How secrets are referenced in host configs
- How secrets are injected into services

### Phase 2: Planning

#### 2.1 Determine Secret Structure

Plan the directory structure for secrets:
```
secrets/
├── <host-name>/
│   └── <service-name>/
│       ├── secret1.age
│       ├── secret2.age
│       └── secret3.age
```

**Example for kometa:**
```
secrets/
└── media-center/
    └── kometa/
        ├── plex-token.age
        ├── mdblist-apikey.age
        └── tmdb-apikey.age
```

#### 2.2 Choose Injection Method

Decide how to inject secrets based on service capabilities:

| Method | Use When | Example |
|--------|----------|---------|
| Environment Variables | Service supports env vars natively | Docker containers, most modern apps |
| Runtime Config Generation | Service needs config file with secrets | Generate config in ExecStart script |
| Secret File Mounting | Service reads from files | Mount agenix paths directly |

#### 2.3 Plan Variable Naming

Create consistent naming conventions:
- **Agenix secret name**: `service-secret-name` (e.g., `kometa-plex-token`)
- **Environment variable**: `SERVICE_SECRETNAME` (e.g., `KOMETA_PLEXTOKEN`)
- **Config placeholder**: Based on service syntax (e.g., `<<plextoken>>`)

**Important considerations:**
- Check service docs for naming requirements (underscores, case sensitivity, etc.)
- Keep names consistent across all layers

### Phase 3: Implementation

#### 3.1 Define Secrets in `secrets.nix`

Add secret definitions using the helper function:

```nix
# secrets.nix
(mkServiceSecrets "<host>" <host-var> "<service>" [
  "secret-name-1"
  "secret-name-2"
  "secret-name-3"
])
```

**Example:**
```nix
(mkServiceSecrets "media-center" media-center "kometa" [
  "plex-token"
  "mdblist-apikey"
  "tmdb-apikey"
])
```

This creates entries like:
```nix
"secrets/media-center/kometa/plex-token.age".publicKeys = [ kyle media-center ];
```

#### 3.2 Create Encrypted Secret Files

Use the provided scripts:

**Option A: Add secrets individually**
```bash
./scripts/add-secret.sh secrets/media-center/kometa/plex-token.age "secret-value"
```

**Option B: Add multiple secrets at once**
```bash
./scripts/add-service-secrets.sh media-center kometa \
  plex-token="secret1" \
  mdblist-apikey="secret2" \
  tmdb-apikey="secret3"
```

**Manual method (if scripts unavailable):**
```bash
SECRET_VALUE="your-secret" EDITOR="sh -c 'echo -n \"\$SECRET_VALUE\" > \"\$1\"' _" \
  agenix -e secrets/host/service/secret-name.age
```

#### 3.3 Update NixOS Module

Add secret options and handling to the module:

**A. Add module options for secret file paths:**
```nix
# modules/service/service.nix
options.custom.service = {
  # ... existing options ...

  secrets = {
    secretFile = lib.mkOption {
      type = lib.types.str;
      default = "../secrets/host/service/secret-name.age";
      description = "Path to agenix encrypted secret file";
    };
  };
};
```

**B. Define agenix secrets in config:**
```nix
config = lib.mkIf cfg.enable {
  age.secrets = {
    service-secret-name = {
      file = cfg.secrets.secretFile;
      owner = cfg.user;
      group = cfg.group;
      mode = "400";  # Read-only by owner
    };
  };
};
```

**C. Inject secrets at runtime:**

**For environment variables:**
```nix
ExecStart = pkgs.writeShellScript "service-run" ''
  set -eu

  # Read secrets
  SECRET_VAR=$(cat ${config.age.secrets.service-secret-name.path})

  # Use in service startup
  service_command --secret="$SECRET_VAR"
'';
```

**For Docker containers:**
```nix
ExecStart = pkgs.writeShellScript "service-run" ''
  SECRET=$(cat ${config.age.secrets.service-secret.path})

  ${pkgs.docker}/bin/docker run \
    -e SERVICE_SECRET="$SECRET" \
    image:tag
'';
```

**Complete example from kometa:**
```nix
ExecStart = pkgs.writeShellScript "kometa-run" ''
  set -eu

  # Read secrets into environment variables
  KOMETA_PLEXTOKEN=$(cat ${config.age.secrets.kometa-plex-token.path})
  KOMETA_MDBLISTAPIKEY=$(cat ${config.age.secrets.kometa-mdblist-apikey.path})
  KOMETA_TMDBAPIKEY=$(cat ${config.age.secrets.kometa-tmdb-apikey.path})

  # Start container with secrets as env vars
  ${pkgs.docker}/bin/docker run --rm \
    -e KOMETA_PLEXTOKEN="$KOMETA_PLEXTOKEN" \
    -e KOMETA_MDBLISTAPIKEY="$KOMETA_MDBLISTAPIKEY" \
    -e KOMETA_TMDBAPIKEY="$KOMETA_TMDBAPIKEY" \
    lscr.io/linuxserver/kometa:latest
'';
```

#### 3.4 Update Configuration Files

Replace hardcoded values with placeholders:

**For services with env var support:**
```yaml
# Before
plex:
  token: rqyWME8LpHPoNwLnFyAG

# After (using Kometa's syntax)
plex:
  token: <<plextoken>>
```

**For services without env var support:**
Generate the config at runtime:
```nix
ExecStart = pkgs.writeShellScript "service-run" ''
  SECRET=$(cat ${config.age.secrets.service-secret.path})

  cat > /var/lib/service/config.yml << EOF
  service:
    token: $SECRET
  EOF

  service_command
'';
```

#### 3.5 Update Host Configuration

Add secret definitions to the host config:

```nix
# hosts/hostname.nix
age.secrets = {
  service-secret-name = {
    file = ../secrets/hostname/service/secret-name.age;
    owner = "service-user";
    group = "service-group";
    mode = "400";
  };
};
```

**Example from media-center.nix:**
```nix
age.secrets = {
  kometa-plex-token = {
    file = ../secrets/media-center/kometa/plex-token.age;
    owner = "kometa";
    group = "media";
    mode = "400";
  };

  kometa-mdblist-apikey = {
    file = ../secrets/media-center/kometa/mdblist-apikey.age;
    owner = "kometa";
    group = "media";
    mode = "400";
  };

  kometa-tmdb-apikey = {
    file = ../secrets/media-center/kometa/tmdb-apikey.age;
    owner = "kometa";
    group = "media";
    mode = "400";
  };
};
```

### Phase 4: Testing and Verification

#### 4.1 Build Test (Pre-deployment)

Test that the configuration builds without errors:
```bash
nixos-rebuild build --flake .#hostname
```

Common errors to watch for:
- Missing secret file references
- Incorrect paths in host config
- Type mismatches in module options
- Undefined config attributes

#### 4.2 Deploy to Target Host

Deploy the configuration:
```bash
# Remote deployment
nixos-rebuild switch --flake .#hostname --target-host hostname

# Local deployment (on the host)
sudo nixos-rebuild switch --flake .#hostname

# Using Colmena
colmena apply --on hostname
```

#### 4.3 Verify Secret Files

Check that agenix created the decrypted secrets:
```bash
# On the target host
ls -la /run/agenix/
# Should show files like:
# -r-------- 1 service-user service-group XX service-secret-name
```

Verify permissions are correct:
- Mode should be `400` or `600` (read-only)
- Owner should be the service user
- Group should be the service group

#### 4.4 Check Service Logs

Monitor the service to ensure it starts correctly:
```bash
# View service logs
journalctl -u service-name.service -f

# Check service status
systemctl status service-name.service
```

Look for:
- Successful secret loading
- No authentication errors
- Service starts without errors
- Connections to external APIs succeed

#### 4.5 Verify Configuration

Confirm secrets aren't exposed in plaintext:
```bash
# Check config file doesn't contain plaintext secrets
cat /var/lib/service/config.yml | grep -E "(token|key|password)"
# Should show placeholders like <<plextoken>>, not actual values

# Check environment variables (if applicable)
# While service is running:
cat /proc/$(pidof service)/environ | tr '\0' '\n' | grep SECRET
```

#### 4.6 Test Service Functionality

Verify the service works end-to-end:
- Trigger the service to perform its primary function
- Confirm it can authenticate with external services
- Check that features requiring secrets work correctly

**Example for Kometa:**
```bash
# Trigger manual run
systemctl start kometa.service

# Check logs for successful authentication
journalctl -u kometa.service | grep -i "authentication\|connected"

# Verify it can fetch data from APIs
journalctl -u kometa.service | grep -i "tmdb\|mdblist\|plex"
```

### Phase 5: Cleanup and Documentation

#### 5.1 Remove Old Secret Files

If you had temporary scripts or old config files:
```bash
rm -f create-service-secrets.sh
# Move old config to backup if needed
mv config.yml config.yml.backup
```

#### 5.2 Update Module Documentation

Add comments to the module explaining:
- What secrets are required
- How secrets are injected
- Example secret values (non-sensitive examples)

```nix
# modules/service/service.nix
# Secrets required:
#   - service-token: Authentication token for service API
#   - service-apikey: API key for external service
#
# Secrets are injected as environment variables:
#   - SERVICE_TOKEN -> Read from age.secrets.service-token.path
#   - SERVICE_APIKEY -> Read from age.secrets.service-apikey.path
```

#### 5.3 Update Repository README

Document the new service's secret requirements in README.md:
```markdown
### Service Name
Requires the following secrets:
- `secrets/host/service/token.age` - Authentication token
- `secrets/host/service/apikey.age` - API key

Create secrets using:
\`\`\`bash
./scripts/add-service-secrets.sh host service \
  token="your-token" \
  apikey="your-key"
\`\`\`
```

#### 5.4 Commit Changes

Commit the changes to version control:
```bash
git add secrets.nix hosts/ modules/ secrets/
git commit -m "Replace hardcoded secrets with agenix for service-name

- Add secret definitions to secrets.nix
- Update module to use agenix secrets
- Add secret references to host config
- Replace hardcoded values in config files with placeholders"
```

**Important:** The `.age` files are safe to commit - they're encrypted and can only be decrypted by authorized hosts.

## Common Patterns and Best Practices

### Secret File Permissions

```nix
mode = "400"  # Read-only by owner (most secure)
mode = "600"  # Read-write by owner (if service needs to modify)
mode = "440"  # Read by owner and group (if multiple services share)
```

### Naming Conventions

| Component | Convention | Example |
|-----------|-----------|---------|
| Secret file | `secret-name.age` | `plex-token.age` |
| Agenix secret | `service-secret-name` | `kometa-plex-token` |
| Env variable | `SERVICE_SECRETNAME` | `KOMETA_PLEXTOKEN` |
| Module option | `secretNameFile` | `plexTokenFile` |

### Secret Injection Patterns

**Pattern 1: Direct Environment Variable**
```nix
ExecStart = pkgs.writeShellScript "run" ''
  export SECRET=$(cat ${config.age.secrets.my-secret.path})
  service --secret="$SECRET"
'';
```

**Pattern 2: Docker Environment Variable**
```nix
ExecStart = pkgs.writeShellScript "run" ''
  SECRET=$(cat ${config.age.secrets.my-secret.path})
  docker run -e SECRET="$SECRET" image:tag
'';
```

**Pattern 3: Config File Generation**
```nix
ExecStart = pkgs.writeShellScript "run" ''
  SECRET=$(cat ${config.age.secrets.my-secret.path})
  cat > /var/lib/service/config.yml << EOF
  service:
    secret: $SECRET
  EOF
  service start
'';
```

**Pattern 4: Multiple Secrets**
```nix
ExecStart = pkgs.writeShellScript "run" ''
  SECRET1=$(cat ${config.age.secrets.service-secret1.path})
  SECRET2=$(cat ${config.age.secrets.service-secret2.path})
  SECRET3=$(cat ${config.age.secrets.service-secret3.path})

  service --secret1="$SECRET1" --secret2="$SECRET2" --secret3="$SECRET3"
'';
```

### Error Handling

Always use `set -eu` in shell scripts to catch errors:
```nix
ExecStart = pkgs.writeShellScript "run" ''
  set -eu  # Exit on error, error on undefined variables

  # If secret file doesn't exist or can't be read, script will fail
  SECRET=$(cat ${config.age.secrets.my-secret.path})

  service --secret="$SECRET"
'';
```

### Cross-Host Secrets

For secrets needed by multiple hosts:
```nix
# secrets.nix
{
  "secrets/service/shared-secret.age".publicKeys = allUsers ++ [ host1 host2 host3 ];
}
```

## Troubleshooting

### Secret File Not Found

**Error:** `cat: /run/agenix/service-secret: No such file or directory`

**Solutions:**
1. Check secret is defined in `secrets.nix`
2. Verify host public key is in the secret's `publicKeys` list
3. Ensure secret file exists: `ls -la secrets/host/service/`
4. Rebuild to trigger agenix decryption

### Permission Denied

**Error:** `cat: /run/agenix/service-secret: Permission denied`

**Solutions:**
1. Check `owner` matches the service user in `age.secrets` definition
2. Verify service user exists: `id service-user`
3. Check file permissions: `ls -la /run/agenix/service-secret`
4. Ensure mode is `400` or `440` and owner is correct

### Service Fails to Authenticate

**Error:** Service logs show authentication failures

**Solutions:**
1. Verify secret value is correct: `agenix -e secrets/path/to/secret.age`
2. Check no trailing newlines in secret: secrets should use `echo -n`
3. Verify environment variable is being set correctly: add debug logging
4. Check service documentation for exact secret format required

### Secret Not Decrypted

**Error:** Service starts but secret isn't available

**Solutions:**
1. Check agenix module is imported in host config
2. Verify `age.identityPaths` points to valid SSH key
3. Ensure SSH host key hasn't changed
4. Re-encrypt secret if host key changed: `agenix -r secrets/path/to/secret.age`

### Build Failures

**Error:** NixOS build fails with attribute errors

**Solutions:**
1. Check all `age.secrets` references match between host and module
2. Verify no typos in secret names
3. Ensure secret file paths are correct (relative to flake root)
4. Check module option types match usage

## Reference: Complete Example

This example shows the complete transformation for the Kometa service:

### Before (Insecure)
```yaml
# modules/kometa/config.yml
plex:
  token: rqyWME8LpHPoNwLnFyAG
mdblist:
  apikey: k0s90j8w4v19sjd3q5zvytl6d
tmdb:
  apikey: 3ba96efb12fe2aafa920f84d4500dfbe
```

### After (Secure)

**1. secrets.nix**
```nix
(mkServiceSecrets "media-center" media-center "kometa" [
  "plex-token"
  "mdblist-apikey"
  "tmdb-apikey"
])
```

**2. Create encrypted files**
```bash
./scripts/add-service-secrets.sh media-center kometa \
  plex-token="rqyWME8LpHPoNwLnFyAG" \
  mdblist-apikey="k0s90j8w4v19sjd3q5zvytl6d" \
  tmdb-apikey="3ba96efb12fe2aafa920f84d4500dfbe"
```

**3. modules/kometa/kometa.nix**
```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.custom.kometa;
in {
  options.custom.kometa = {
    enable = lib.mkEnableOption "Kometa";

    secrets = {
      plexTokenFile = lib.mkOption {
        type = lib.types.str;
        default = "../secrets/media-center/kometa/plex-token.age";
      };
      mdblistApiKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "../secrets/media-center/kometa/mdblist-apikey.age";
      };
      tmdbApiKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "../secrets/media-center/kometa/tmdb-apikey.age";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets = {
      kometa-plex-token = {
        file = cfg.secrets.plexTokenFile;
        owner = "kometa";
        mode = "400";
      };
      kometa-mdblist-apikey = {
        file = cfg.secrets.mdblistApiKeyFile;
        owner = "kometa";
        mode = "400";
      };
      kometa-tmdb-apikey = {
        file = cfg.secrets.tmdbApiKeyFile;
        owner = "kometa";
        mode = "400";
      };
    };

    systemd.services.kometa = {
      serviceConfig = {
        ExecStart = pkgs.writeShellScript "kometa-run" ''
          set -eu

          KOMETA_PLEXTOKEN=$(cat ${config.age.secrets.kometa-plex-token.path})
          KOMETA_MDBLISTAPIKEY=$(cat ${config.age.secrets.kometa-mdblist-apikey.path})
          KOMETA_TMDBAPIKEY=$(cat ${config.age.secrets.kometa-tmdb-apikey.path})

          docker run \
            -e KOMETA_PLEXTOKEN="$KOMETA_PLEXTOKEN" \
            -e KOMETA_MDBLISTAPIKEY="$KOMETA_MDBLISTAPIKEY" \
            -e KOMETA_TMDBAPIKEY="$KOMETA_TMDBAPIKEY" \
            lscr.io/linuxserver/kometa:latest
        '';
      };
    };
  };
}
```

**4. modules/kometa/config.yml**
```yaml
plex:
  token: <<plextoken>>
mdblist:
  apikey: <<mdblistapikey>>
tmdb:
  apikey: <<tmdbapikey>>
```

**5. hosts/media-center.nix**
```nix
{
  age.secrets = {
    kometa-plex-token = {
      file = ../secrets/media-center/kometa/plex-token.age;
      owner = "kometa";
      group = "media";
      mode = "400";
    };
    kometa-mdblist-apikey = {
      file = ../secrets/media-center/kometa/mdblist-apikey.age;
      owner = "kometa";
      group = "media";
      mode = "400";
    };
    kometa-tmdb-apikey = {
      file = ../secrets/media-center/kometa/tmdb-apikey.age;
      owner = "kometa";
      group = "media";
      mode = "400";
    };
  };
}
```

**6. Deploy**
```bash
nixos-rebuild switch --flake .#media-center
```

## Summary Checklist

- [ ] Identify all hardcoded secrets in the module
- [ ] Research service's secret injection capabilities
- [ ] Plan secret structure and naming
- [ ] Define secrets in `secrets.nix`
- [ ] Create encrypted `.age` files
- [ ] Add secret options to module
- [ ] Define `age.secrets` in module config
- [ ] Update service startup to inject secrets
- [ ] Replace hardcoded values in config files
- [ ] Add secret definitions to host config
- [ ] Build and deploy to target host
- [ ] Verify secret file permissions
- [ ] Check service logs for errors
- [ ] Test service functionality
- [ ] Update documentation
- [ ] Commit changes to version control

## Resources

- [Agenix GitHub](https://github.com/ryantm/agenix)
- [Age Encryption](https://github.com/FiloSottile/age)
- [NixOS Options Search](https://search.nixos.org/options)
- This repository's README.md for specific usage examples
