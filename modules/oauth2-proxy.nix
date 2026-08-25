{ config, lib, pkgs, ... }:

let
  cfg = config.custom.oauth2-proxy;
in {
  options.custom.oauth2-proxy = {
    enable = lib.mkEnableOption "oauth2-proxy as a Traefik ForwardAuth backend for Zitadel";

    port = lib.mkOption {
      type = lib.types.port;
      default = 4180;
      description = "Port oauth2-proxy listens on";
    };

    zitadelDomain = lib.mkOption {
      type = lib.types.str;
      description = "Domain of the Zitadel OIDC issuer (e.g. auth.example.com)";
    };

    redirectUrl = lib.mkOption {
      type = lib.types.str;
      description = "OAuth2 redirect URL registered with Zitadel (e.g. https://oauth.example.com/oauth2/callback)";
    };

    cookieDomain = lib.mkOption {
      type = lib.types.str;
      description = "Cookie domain, e.g. .example.com";
    };

    clientId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Zitadel OIDC client ID (not secret; empty string disables until configured)";
    };

    clientSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to a file containing the Zitadel OIDC client secret";
    };

    cookieSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to a file containing the oauth2-proxy cookie secret";
    };
  };

  config = lib.mkIf cfg.enable {
    # services.oauth2-proxy.clientSecret / cookie.secret are plain strings
    # that would otherwise land in the Nix store and in ExecStart's argv (ps
    # aux). Route them through keyFile -> systemd's EnvironmentFile instead,
    # which oauth2-proxy reads as OAUTH2_PROXY_CLIENT_SECRET / _COOKIE_SECRET.
    systemd.services.oauth2-proxy-env = {
      description = "Generate oauth2-proxy runtime environment file";
      before = [ "oauth2-proxy.service" ];
      wantedBy = [ "oauth2-proxy.service" ];
      # No RemainAfterExit: must re-run on every (re)start so a rotated
      # secret file is picked up, not just on first boot.
      serviceConfig.Type = "oneshot";
      script = ''
        umask 077
        install -d -o oauth2-proxy -g oauth2-proxy -m 0750 /run/oauth2-proxy
        cat > /run/oauth2-proxy/env <<EOF
        OAUTH2_PROXY_CLIENT_SECRET=$(cat ${cfg.clientSecretFile})
        OAUTH2_PROXY_COOKIE_SECRET=$(cat ${cfg.cookieSecretFile})
        EOF
        chown oauth2-proxy:oauth2-proxy /run/oauth2-proxy/env
      '';
    };

    services.oauth2-proxy = {
      enable = true;
      provider = "oidc";
      # Default bind is loopback-only; Traefik reaches this over the LAN
      # from a different host, so it must listen on all interfaces.
      httpAddress = "http://0.0.0.0:${toString cfg.port}";
      oidcIssuerUrl = "https://${cfg.zitadelDomain}";
      redirectURL = cfg.redirectUrl;
      # ForwardAuth mode: there's no real upstream to proxy to, Traefik
      # routes to the actual backend itself once this returns 200.
      upstream = "static://200";
      reverseProxy = true;
      setXauthrequest = true;
      passAccessToken = true;
      # Without this, oauth2-proxy's own Basic-auth header (empty password)
      # overwrites the Authorization header instead of the Bearer token
      # that pass-authorization-header (below) is meant to forward.
      passBasicAuth = false;
      cookie = {
        domain = cfg.cookieDomain;
        secure = true;
      };
      # Zitadel is the actual authorization boundary; oauth2-proxy just
      # needs *a* validation rule or it refuses to start at all (see
      # pkg/validation/options.go: "missing setting for email validation").
      email.domains = [ "*" ];
      clientID = if cfg.clientId != "" then cfg.clientId else null;
      keyFile = "/run/oauth2-proxy/env";
      # codeChallengeMethod / passAuthorizationHeader aren't declared options
      # on this module; both only exist as raw oauth2-proxy flags.
      extraConfig = {
        code-challenge-method = "S256";
        pass-authorization-header = true;
        # Without this, oauth2-proxy rejects the post-login "rd" redirect
        # target (e.g. https://whoami.goobtube.tv/) as "domain / port not
        # in whitelist" and silently drops it, landing the user on a
        # default page instead of the service they originally requested.
        # cfg.cookieDomain is already the right wildcard value (".goobtube.tv").
        whitelist-domain = cfg.cookieDomain;
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
