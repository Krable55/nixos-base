{ config, pkgs, lib, ... }:

let
  # Zitadel OIDC discovery URL
  discovery = "https://zitadel.example.com/.well-known/openid-configuration";
  clientId   = "my-nixos-client";
in {
  # 1) Vault agent auto‑auth via Zitadel OIDC
  services.vault = {
    enable    = true;
    package   = pkgs.vault;
    agentConfig = {
      autoAuth = {
        method = {
          type       = "oidc";
          mountPath  = "auth/oidc";
          config = {
            oidc_discovery_url = discovery;
            client_id          = clientId;
            client_secret_file = "/etc/zitadel/client-secret";
            role               = "nixos-role";
          };
        };
        sink = {
          type = "file";
          config = { path = "/run/vault/token"; };
        };
      };
      cache = { use_auto_auth_token = true; };
    };
  };

  # 2) Fetch your age.key at boot
  systemd.services.fetch-age-key = {
    after  = [ "vault.service" ];
    wants  = [ "vault.service" ];
    serviceConfig = {
      Type        = "oneshot";
      ExecStart   = "${pkgs.vault}/bin/vault kv get -field=key secret/age-key > /etc/age.key";
      User        = "root";
      Group       = "root";
      RemainAfterExit = true;
    };
  };

  # 3) Put your Zitadel client secret on disk (out‑of‑band)
  environment.etc."zitadel/client-secret" = {
    source = ./secrets/zitadel-client-secret;
    user   = "root"; group = "root"; mode = "0400";
  };

  # 4) Now SOPS‑Nix can hydrate your secrets from /etc/age.key
  imports = [ inputs.sops-nix.nixosModules.sops ];
  security.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile     = "/etc/age.key";
    secrets.tailscale-authkey = {
      owner = "root"; group = "root"; path = "/var/lib/tailscale/authkey";
    };
  };
}
