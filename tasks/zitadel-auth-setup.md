# Zitadel Authentication Setup Plan

## Task Tracking

Tasks are tracked in: **`tasks/zitadel-auth-setup.json`**

| Phase | Name | Tasks |
|-------|------|-------|
| 1 | Secrets Infrastructure | 6 |
| 2 | Zitadel Module | 5 |
| 3 | oauth2-proxy Module | 4 |
| 4 | Auth Host Configuration | 5 |
| 5 | Traefik Updates | 6 |
| 6 | First Deployment | 5 |
| 7 | Zitadel UI Configuration (manual) | 5 |
| 8 | oauth2-proxy Secrets | 3 |
| 9 | Enable oauth2-proxy | 4 |
| 10 | Verification | 4 |

**Total: 10 phases, 47 tasks**

## Overview

Set up Zitadel as a native NixOS service on the auth host (192.168.50.125) with PostgreSQL, and integrate it with Traefik for ForwardAuth to protect web applications.

**Key Finding**: Zitadel does NOT natively support ForwardAuth. We need **oauth2-proxy** as an intermediary between Traefik's ForwardAuth middleware and Zitadel's OIDC provider.

## Architecture

```
User Request --> Traefik (networking:443)
                      |
                ForwardAuth middleware
                      |
               oauth2-proxy (auth:4180)
                      |
               Zitadel OIDC (auth:8080)
                      |
               If authenticated --> Backend service
```

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `modules/zitadel.nix` | Create | Zitadel + PostgreSQL module |
| `modules/oauth2-proxy.nix` | Create | oauth2-proxy ForwardAuth module |
| `hosts/auth.nix` | Rewrite | Enable Zitadel + oauth2-proxy |
| `modules/traefik.nix` | Modify | Fix IPs, uncomment middlewares |
| `secrets.nix` | Modify | Add auth host key + secrets |
| `secrets/auth/zitadel/*.age` | Create | Zitadel secrets |
| `secrets/auth/oauth2-proxy/*.age` | Create | oauth2-proxy secrets |

---

## Implementation Steps

### Step 1: Add Auth Host Key to secrets.nix

Get the auth host's SSH public key and add to `secrets.nix`:

```nix
auth = "ssh-ed25519 AAAAC3...";  # From: ssh root@192.168.50.125 cat /etc/ssh/ssh_host_ed25519_key.pub

allSystems = [ media-center builder networking powerball trader auth ];
```

Add secrets definitions:
```nix
(mkServiceSecrets "auth" auth "zitadel" [
  "master-key"
  "postgres-password"
  "postgres-admin-password"
])
(mkServiceSecrets "auth" auth "oauth2-proxy" [
  "client-secret"
  "cookie-secret"
])
```

### Step 2: Create Zitadel Secrets

```bash
# 32-byte master key for encryption
openssl rand -base64 32 | head -c 32 | ./scripts/add-secret.sh secrets/auth/zitadel/master-key.age

# PostgreSQL passwords
openssl rand -base64 24 | ./scripts/add-secret.sh secrets/auth/zitadel/postgres-password.age
openssl rand -base64 24 | ./scripts/add-secret.sh secrets/auth/zitadel/postgres-admin-password.age
```

### Step 3: Create modules/zitadel.nix

Custom module that:
- Enables PostgreSQL 16 with `zitadel` database
- Configures `services.zitadel` with:
  - `tlsMode = "external"` (TLS at Traefik)
  - PostgreSQL via Unix socket
  - `extraSettingsPaths` for database passwords
- Sets up initial admin user via `steps.FirstInstance`
- Generates runtime secrets file via systemd

Key settings:
```nix
services.zitadel = {
  enable = true;
  masterKeyFile = cfg.masterKeyFile;
  tlsMode = "external";
  settings = {
    Port = 8080;
    ExternalDomain = "auth.goobtube.tv";
    ExternalSecure = true;
    ExternalPort = 443;
    Database.postgres = {
      Host = "/run/postgresql";
      Database = "zitadel";
    };
  };
};
```

### Step 4: Create modules/oauth2-proxy.nix

Custom module that:
- Enables `services.oauth2-proxy` with OIDC provider
- Configures for ForwardAuth mode (`upstream = "static://200"`)
- Sets PKCE (`code-challenge-method = "S256"`)
- Passes auth headers to backends

Key settings:
```nix
services.oauth2-proxy = {
  enable = true;
  provider = "oidc";
  extraConfig = {
    oidc-issuer-url = "https://auth.goobtube.tv";
    redirect-url = "https://oauth.goobtube.tv/oauth2/callback";
    upstream = "static://200";
    set-xauthrequest = true;
    pass-access-token = true;
  };
};
```

### Step 5: Rewrite hosts/auth.nix

Replace the placeholder config with:
- Import `zitadel.nix` and `oauth2-proxy.nix` modules
- Configure agenix secrets for all credentials
- Enable both services with correct paths
- Configure Tailscale and firewall (ports 22, 8080, 4180)

### Step 6: Update modules/traefik.nix

**Fix zitadel-backend IP** (line 583):
```nix
# Change from 192.168.50.244 to 192.168.50.125
servers = [ { url = "h2c://192.168.50.125:8080"; } ];
```

**Add oauth2-proxy-backend**:
```nix
"oauth2-proxy-backend" = {
  loadBalancer = {
    servers = [ { url = "http://192.168.50.125:4180"; } ];
  };
};
```

**Uncomment and update middlewares** (lines 91-110):
```nix
"oauth-auth-redirect" = {
  forwardAuth = {
    address = "http://192.168.50.125:4180/oauth2/auth";
    trustForwardHeader = true;
    authResponseHeaders = [
      "X-Auth-Request-User"
      "X-Auth-Request-Email"
      "X-Auth-Request-Access-Token"
      "Authorization"
    ];
  };
};

"oauth-errors" = {
  errors = {
    query = "/oauth2/start?rd={scheme}://{host}{uri}";
    service = "oauth2-proxy-backend";
    status = [ "401-403" ];
  };
};
```

**Uncomment header-forward middleware** (lines 73-81).

**Add oauth2-proxy router**:
```nix
"oauth2-proxy" = {
  rule = "Host(`oauth.goobtube.tv`) && PathPrefix(`/oauth2`)";
  service = "oauth2-proxy-backend";
  tls = { certResolver = "leresolver"; ... };
};
```

---

## Deployment Order

1. **Create secrets** - Generate and encrypt all secrets with agenix
2. **Deploy auth host** (Zitadel only, oauth2-proxy disabled initially)
3. **Wait for Zitadel init** - Check logs: `journalctl -u zitadel -f`
4. **Configure Zitadel UI**:
   - Login at `https://auth.goobtube.tv`
   - Create project -> application (Web, Authorization Code + PKCE)
   - Redirect URI: `https://oauth.goobtube.tv/oauth2/callback`
   - Copy Client ID and Client Secret
5. **Create oauth2-proxy secrets** with client credentials
6. **Enable oauth2-proxy** and redeploy auth host
7. **Update Traefik** on networking host
8. **Test authentication** on protected services

---

## Protected Services (Same as Current)

These routers already have `middlewares = [ "oauth-errors" "oauth-auth-redirect" ]`:
- audiobooks, code, deluge, kavita, library, lidarr, mealie
- n8n, podgrab, prowlarr, radarr, readarr, sab, sonarr
- tautulli, traefik, uptime, whoami, faasd

---

## Verification

1. **Zitadel health**: `curl -k https://auth.goobtube.tv/debug/healthz`
2. **oauth2-proxy health**: `curl http://192.168.50.125:4180/ping`
3. **Auth flow test**: Access any protected service -> should redirect to Zitadel login
4. **Check headers**: Access `whoami.goobtube.tv` after login -> verify X-Auth-Request-* headers

---

## Notes

- **h2c**: Zitadel uses gRPC requiring HTTP/2. With TLS at Traefik, use `h2c://` (HTTP/2 cleartext)
- **passHostHeader**: Already `true` in config - required for Zitadel URL generation
- **Cookie domain**: Use `.goobtube.tv` (leading dot) for SSO across all subdomains
- **DNS**: Both `auth.goobtube.tv` and `oauth.goobtube.tv` CNAME records already exist
