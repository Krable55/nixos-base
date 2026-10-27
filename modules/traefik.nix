{ config, pkgs, lib, ... }:

let
  cfg = config.custom.traefik;
in
{
  options.custom.traefik.enable = lib.mkEnableOption
    "Enable the Traefik reverse‑proxy on this host";

  config = lib.mkIf cfg.enable {
   services.traefik = {
    enable  = true;
    package = pkgs.traefik;

    staticConfigOptions = {
       entryPoints = {
        web = {
          address = ":80";
          asDefault = true;
          http.redirections.entrypoint = {
            to = "websecure";
            scheme = "https";
          };
        };

        websecure = {
          address = ":443";
          asDefault = true;
          http.tls.certResolver = "leresolver";
        };
      }; 
      # ─── ACME via Cloudflare ─────────────────────────────────────────────────────
      certificatesResolvers = {
        leresolver = {
          acme = {
            dnsChallenge = { provider = "cloudflare"; };
            email        = "kyle.rable@outlook.com";
            storage      = "${config.services.traefik.dataDir}/acme.json";
          };
        };
      };

      # Access the Traefik dashboard on <Traefik IP>:8080 of your server
      api.dashboard = true;
      api.insecure = true;

      log = {
        level = "DEBUG";
        filePath = "${config.services.traefik.dataDir}/traefik.log";
        format = "json";
      };
    };

    dynamicConfigOptions = {
      http = {
        # ─── Middlewares ────────────────────────────────────────────────────────────
        middlewares = {
          # "auth-headers" = {
          #   headers = {
          #     browserXssFilter      = true;
          #     contentTypeNosniff    = true;
          #     forceSTSHeader        = true;
          #     frameDeny             = true;
          #     sslForceHost          = true;
          #     sslHost               = "auth.goobtube.tv";
          #     sslRedirect           = true;
          #     stsIncludeSubdomains  = true;
          #     stsPreload            = true;
          #     stsSeconds            = 315360000;
          #   };
          # };

          "header-forward" = {
            headers = {
              customRequestHeaders = {
                "Set-Cookie"        = "Secure; SameSite=None";
                "X-Forwarded-Host"  = "auth.goobtube.tv";
                "X-Forwarded-Proto" = "https";
              };
            };
          };

          # websocket = {
          #   headers = {
          #     allowWebsocket         = true;
          #     customRequestHeaders   = { "X-Forwarded-Proto" = "https"; };
          #     customResponseHeaders  = { "Access-Control-Allow-Origin" = "*"; };
          #   };
          # };

          # Enabled: custom.oauth2-proxy.enable = true shipped to the auth
          # host (task 9.3/9.4) and oauth2-proxy is confirmed answering
          # http://192.168.50.125:4180/ping with 200, so ForwardAuth has
          # something real to call now.
          #
          # (addAuthCookiesToResponse deliberately omitted: the original
          # placeholder listed "Session-Cookie"/"State-Cookie", but the real
          # oauth2-proxy module never overrides cookie.name, so the actual
          # cookie is "_oauth2_proxy". Forwarding the wrong cookie name here
          # is exactly what causes the infinite-redirect-loop symptom Phase
          # 10.3 warns about, since the session would never persist.)
          "oauth-auth-redirect" = {
            forwardAuth = {
              address             = "http://192.168.50.125:4180/oauth2/auth";
              authResponseHeaders = [
                "X-Auth-Request-User"
                "X-Auth-Request-Email"
                "X-Auth-Request-Access-Token"
                "Authorization"
              ];
              trustForwardHeader  = true;
            };
          };

          # {url} is the only real placeholder Traefik substitutes here
          # ({scheme}/{host}/{uri} aren't real and were passed through
          # literally, which oauth2-proxy rejected as an invalid redirect --
          # see journalctl -u oauth2-proxy: "not an absolute or relative
          # URL"). statusRewrites is required too: without it, Traefik keeps
          # the original 401 status even though the fetched oauth2-proxy
          # page is a real 302, so the browser never auto-follows -- it
          # renders a bare "Found" link instead, which leaves enough of a
          # window for the browser's automatic /favicon.ico request (same
          # Host, same ForwardAuth chain) to overwrite the PKCE CSRF cookie
          # before the link is clicked, causing Zitadel's token exchange to
          # fail with "invalid code challenge".
          "oauth-errors" = {
            errors = {
              query   = "/oauth2/start?rd={url}";
              service = "oauth2-proxy-backend";
              status  = [ "401-403" ];
              statusRewrites = {
                "401" = 302;
              };
            };
          };

          # obsidiancors = {
          #   headers = {
          #     accessControlAllowCredentials = true;
          #     accessControlAllowHeaders      = [
          #       "accept" "authorization" "content-type" "origin" "referer"
          #     ];
          #     accessControlAllowMethods      = [
          #       "GET" "OPTIONS" "PUT" "POST" "HEAD" "DELETE"
          #     ];
          #     accessControlAllowOriginList   = [
          #       "app://obsidian.md" "capacitor://localhost" "http://localhost"
          #     ];
          #     accessControlMaxAge             = 3600;
          #     addVaryHeader                   = true;
          #   };
          # };

          "redirect-to-https" = {
            redirectScheme = {
              permanent = true;
              port      = 443;
              scheme    = "https";
            };
          };

          zitadel = {
            headers = {
              isDevelopment         = false;
              allowedHosts          = [ "auth.goobtube.tv" ];
              customRequestHeaders  = { authority = "auth.goobtube.tv"; };
            };
          };

          "zitadel-auth" = {
            forwardAuth = {
              address             = "https://auth.goobtube.tv/auth";
              trustForwardHeader  = true;
              authResponseHeaders = [
                "X-Auth-Request-User"
                "X-Auth-Request-Email"
                "X-Auth-Request-Access-Token"
                "X-Auth-Request-Groups"
                "Authorization"
              ];
            };
          };
        };

        # ─── Routers ───────────────────────────────────────────────────────────────
        routers = {
          audiobooks = {
            rule       = "Host(`audiobooks.goobtube.tv`)";
            service    = "audiobooks-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          atuin = {
            rule    = "Host(`atuin.goobtube.tv`)";
            service = "atuin-backend";
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          # code-server was never actually deployed anywhere in the fleet
          # (checked every host's colmena config and the NAS's docker ps on
          # 2026-08-09) -- router removed rather than left pointing at
          # nothing. Re-add if code-server gets deployed somewhere.

          # Deluge doesn't exist anywhere either -- the only torrent client
          # in the whole fleet is qBittorrent, running natively on the
          # networking host, NFS-mounted into the same download path, not
          # the Docker copy on the NAS
          # this router used to point at. Kept the hostname as
          # deluge.goobtube.tv rather than renaming to qbittorrent.goobtube.tv
          # since that would need a new DNS record that can't be verified or
          # created from here -- rename once that record exists.
          deluge = {
            rule       = "Host(`deluge.goobtube.tv`) && PathPrefix(`/`)";
            service    = "deluge-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          # Gated behind Zitadel 2026-08-09 after finding all 13 repos here
          # (including one named "homelab-secrets") were publicly readable
          # anonymously via Forgejo's own API, plus open self-registration.
          # Note: this blanket-protects the whole host, including
          # git-over-HTTPS smart-HTTP endpoints -- `git clone`/`push`
          # against https://git.goobtube.tv/... will now hit the Zitadel
          # redirect instead of Forgejo's git protocol responses. Forgejo's
          # advertised clone URLs already use the LAN IP directly
          # (http://192.168.50.243:3000/... and ssh://...), not this public
          # hostname, so this is expected to only affect browser access to
          # the public domain.
          git = {
            rule        = "Host(`git.goobtube.tv`) && PathPrefix(`/`)";
            service     = "gitea-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls         = true;
          };

          # immich and kavita: same as code-server above -- no matching
          # container/service anywhere in the fleet or on the NAS, routers
          # removed. Re-add if/when actually deployed.

          library = {
            rule       = "Host(`library.goobtube.tv`) && PathPrefix(`/`)";
            service    = "library-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          lidarr = {
            rule       = "Host(`lidarr.goobtube.tv`) && PathPrefix(`/`)";
            service    = "lidarr-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          # mealie: no matching container/service anywhere -- removed, same
          # as code-server/immich/kavita above.

          # n8n-backend was referenced here but never actually defined
          # anywhere in this file -- this router was hard-broken (undefined
          # service), not just misrouted. n8n runs natively on the builder
          # host (192.168.50.243:5678, see modules/n8n.nix); backend added
          # below to match.
          n8n = {
            rule       = "Host(`n8n.goobtube.tv`) && PathPrefix(`/`)";
            service    = "n8n-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          # "oauth2-proxy-route" (legacy root router pointing at
          # 192.168.50.154:4180) removed: it referenced the "auth-headers"
          # middleware, which is commented out above, so it was already
          # hard-broken, and it predates the real oauth2-proxy setup on the
          # auth host entirely. The router below is the actual one Zitadel's
          # oauth-auth-redirect calls into.
          #
          # Explicit priority so this can't lose PathPrefix precedence to a
          # future edit of another oauth.goobtube.tv rule, even though its
          # longer rule string already wins under Traefik's default
          # length-based priority.
          "oauth2-proxy" = {
            rule       = "Host(`oauth.goobtube.tv`) && PathPrefix(`/oauth2`)";
            service    = "oauth2-proxy-backend";
            priority   = 100;
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          # obsidian-livesync (CouchDB backend): no matching service
          # anywhere -- removed, same as the others above.

          overseerr = {
            rule    = "Host(`watch.goobtube.tv`) && PathPrefix(`/`)";
            service = "overseerr-backend";
            tls     = true;
          };

          plex = {
            rule    = "Host(`plex.goobtube.tv`) && PathPrefix(`/`)";
            service = "plex-backend";
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          # podgrab: no matching service anywhere -- removed, same as the
          # others above.

          portainer = {
            rule    = "Host(`portainer.goobtube.tv`)";
            service = "portainer-backend";
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          prowlarr = {
            rule       = "Host(`prowlarr.goobtube.tv`) && PathPrefix(`/`)";
            service    = "prowlarr-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          radarr = {
            rule       = "Host(`radarr.goobtube.tv`) && PathPrefix(`/`)";
            service    = "radarr-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          # readarr: the container exists on the NAS (image
          # ghcr.io/hotio/readarr) but is currently stopped -- router
          # removed rather than left pointing at a dead port. Re-add once
          # the container is running again.

          sab = {
            rule       = "Host(`sab.goobtube.tv`) && PathPrefix(`/`)";
            service    = "sab-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          sonarr = {
            rule       = "Host(`sonarr.goobtube.tv`) && PathPrefix(`/`)";
            service    = "sonarr-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          tautulli = {
            rule       = "Host(`tautulli.goobtube.tv`) && PathPrefix(`/`)";
            service    = "tautulli-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          traefik = {
            rule       = "Host(`traefik.goobtube.tv`)";
            service    = "traefik-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          # uptime (Uptime Kuma): no matching service anywhere -- removed,
          # same as the others above.

          faasd = {
            rule       = "Host(`faas.goobtube.tv`)";
            service    = "faasd-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          "faasd-portal" = {
            rule       = "Host(`faas.goobtube.tv`) && PathPrefix(`/ui`)";
            service    = "faasd-portal-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          zitadel = {
            rule       = "Host(`auth.goobtube.tv`) && PathPrefix(`/`)";
            service    = "zitadel-backend";
            middlewares = [ "header-forward" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "auth.goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };
        };

        # ─── Servers Transports ────────────────────────────────────────────────────
        serversTransports = {
          zitadel = { insecureSkipVerify = false; };
        };

        # ─── Backend Services ─────────────────────────────────────────────────────
        services = {
          # audiobookshelf (the container matching this port, 13378) is
          # stopped on the NAS. ReadMeABook is the audiobook app actually
          # running there instead, so pointing here rather than at a dead
          # container -- confirm this is really the intended replacement.
          "audiobooks-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:3030"; } ];
            };
          };
          "deluge-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.69:8089"; } ];
            };
          };
          # Forgejo (Gitea-compatible), native on the builder host --
          # nothing named "gitea" exists anywhere in the fleet or the NAS.
          "gitea-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.243:3000"; } ];
            };
          };
          "library-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:5299"; } ];
            };
          };
          "lidarr-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8686"; } ];
            };
          };
          # n8n: native on the builder host -- this service was referenced
          # by the n8n router but never actually defined until now.
          "n8n-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.243:5678"; } ];
            };
          };
          "overseerr-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.64:5055"; } ];
            };
          };
          "plex-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:32400"; } ];
            };
          };
          "portainer-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:9000"; } ];
            };
          };
          "prowlarr-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:9696"; } ];
            };
          };
          "radarr-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:7878"; } ];
            };
          };
          # sabnzbd: native on the networking host, confirmed at :8090
          # ("SABnzbd - Log in"). The NAS also runs a Docker copy of
          # sabnzbd on the same port number (different host, no collision)
          # -- left that one alone, this is the one paired with the native
          # qBittorrent+VPN download path.
          "sab-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.69:8090"; } ];
            };
          };
          "sonarr-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8989"; } ];
            };
          };
          # Tautulli is native on media-center, confirmed at :8181
          # ("Tautulli - Login"). The NAS's port 8181 is actually Calibre.
          "tautulli-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.64:8181"; } ];
            };
          };
          # The real Traefik dashboard -- same host as Traefik itself.
          # This previously pointed at 192.168.50.154:8080, which is
          # actually qBittorrent's WebUI on the NAS.
          "traefik-backend" = {
            loadBalancer = {
              servers = [ { url = "http://127.0.0.1:8080"; } ];
            };
          };
          "faasd-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.69:8081"; } ];
            };
          };
          
          "faasd-portal-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.69:8081/function/portal"; } ];
            };
          };

          "zitadel-backend" = {
            loadBalancer = {
              passHostHeader = true;
              servers        = [ { url = "h2c://192.168.50.125:8080"; } ];
            };
          };

          "oauth2-proxy-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.125:4180"; } ];
            };
          };

          "atuin-backend" = {
            loadBalancer = {
              servers = [ { url = "http://127.0.0.1:8888"; } ];
            };
          };
        };
      };
    };

  };

  systemd.tmpfiles.rules = [
    "d /etc/traefik/dynamic 0755 root root -"
    "z /etc/traefik/dynamic 0700 root root -"
  ];

};
}