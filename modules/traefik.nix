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

          # "header-forward" = {
          #   headers = {
          #     customRequestHeaders = {
          #       "Set-Cookie"        = "Secure; SameSite=None";
          #       "X-Forwarded-Host"  = "auth.goobtube.tv";
          #       "X-Forwarded-Proto" = "https";
          #     };
          #   };
          # };

          # websocket = {
          #   headers = {
          #     allowWebsocket         = true;
          #     customRequestHeaders   = { "X-Forwarded-Proto" = "https"; };
          #     customResponseHeaders  = { "Access-Control-Allow-Origin" = "*"; };
          #   };
          # };

          # "oauth-auth-redirect" = {
          #   forwardAuth = {
          #     address                    = "http://oauth2-proxy:4180";
          #     addAuthCookiesToResponse   = [ "Session-Cookie" "State-Cookie" ];
          #     authResponseHeaders        = [
          #       "X-Auth-Request-Access-Token"
          #       "X-Forwarded-Uri"
          #       "Authorization"
          #     ];
          #     trustForwardHeader         = true;
          #   };
          # };

          # "oauth-errors" = {
          #   errors = {
          #     query   = "/oauth2/start?rd={scheme}://{host}{uri}";
          #     service = "oauth-backend";
          #     status  = [ "401-403" ];
          #   };
          # };

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

          code = {
            rule       = "Host(`code.goobtube.tv`) && PathPrefix(`/`)";
            service    = "code-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          deluge = {
            rule       = "Host(`deluge.goobtube.tv`) && PathPrefix(`/`)";
            service    = "deluge-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          git = {
            rule    = "Host(`git.goobtube.tv`) && PathPrefix(`/`)";
            service = "gitea-backend";
            tls     = true;
          };

          immich = {
            rule    = "Host(`immich.goobtube.tv`)";
            service = "immich-backend";
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          kavita = {
            rule       = "Host(`kavita.goobtube.tv`) && PathPrefix(`/`)";
            service    = "kavita-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

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

          mealie = {
            rule       = "Host(`mealie.goobtube.tv`) && PathPrefix(`/`)";
            service    = "mealie-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          n8n = {
            rule       = "Host(`n8n.goobtube.tv`) && PathPrefix(`/`)";
            service    = "n8n-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          "oauth2-proxy-route" = {
            rule       = "Host(`oauth.goobtube.tv`) && PathPrefix(`/`)";
            service    = "oauth-backend";
            middlewares = [ "auth-headers" ];
            tls = {
              certResolver = "default";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          "obsidian-livesync" = {
            rule       = "Host(`obsidian.goobtube.tv`) && PathPrefix(`/`)";
            service    = "obsidian-livesync-backend";
            middlewares = [ "obsidiancors" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          overseerr = {
            rule    = "Host(`watch.goobtube.tv`) && PathPrefix(`/`)";
            service = "overseerr-backend";
            tls     = true;
          };

          plex = {
            rule    = "Host(`plex.goobtube.tv`) && PathPrefix(`/`)";
            service = "plex-backend";
            tls = {
              certResolver = "default";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          podgrab = {
            rule       = "Host(`podgrab.goobtube.tv`) && PathPrefix(`/`)";
            service    = "podgrab-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

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

          readarr = {
            rule       = "Host(`readarr.goobtube.tv`) && PathPrefix(`/`)";
            service    = "readarr-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

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

          uptime = {
            rule       = "Host(`uptime.goobtube.tv`) && PathPrefix(`/`)";
            service    = "uptime-backend";
            middlewares = [ "oauth-errors" "oauth-auth-redirect" ];
            tls = {
              certResolver = "leresolver";
              domains = [ { main = "goobtube.tv"; sans = [ "*.goobtube.tv" ]; } ];
            };
          };

          whoami = {
            rule       = "Host(`whoami.goobtube.tv`)";
            service    = "whoami-backend";
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
          "audiobooks-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:13378"; } ];
            };
          };
          "code-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8449"; } ];
            };
          };
          "deluge-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8112"; } ];
            };
          };
          "gitea-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:159"; } ];
            };
          };
          "immich-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:2283"; } ];
            };
          };
          "kavita-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:5000"; } ];
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
          "mealie-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:9925"; } ];
            };
          };
          "oauth-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:4180"; } ];
            };
          };
          "obsidian-livesync-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:5984"; } ];
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
          "podgrab-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8180"; } ];
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
          "readarr-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8787"; } ];
            };
          };
          "sab-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8888"; } ];
            };
          };
          "sonarr-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8989"; } ];
            };
          };
          "tautulli-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8181"; } ];
            };
          };
          "traefik-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:8080"; } ];
            };
          };
          "uptime-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:3027"; } ];
            };
          };
          "whoami-backend" = {
            loadBalancer = {
              servers = [ { url = "http://192.168.50.154:80"; } ];
            };
          };
          "zitadel-backend" = {
            loadBalancer = {
              passHostHeader = true;
              servers        = [ { url = "h2c://192.168.50.244:8080"; } ];
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