{ config, pkgs, lib, modulesPath, ... }:

{
  # Enable Traefik with dynamic config directory
  imports = [ 
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/nfs.nix
    ../modules/create-ssh.nix
    ../modules/qbittorrent.nix
    ../modules/wireguard-nord.nix
    ../modules/traefik.nix
    ../modules/cloudflared.nix
    ../modules/claude-code.nix
    ../modules/agenix.nix
    ../modules/atuin.nix
    ../modules/nuclio
    ../modules/nuclio/functions.nix
  ];
  
  networking.hostName = "network";
  custom.qbittorrent.enable = true;
  custom.wgnord.enable = true;
  custom.cloudflared.enable = true;
  custom.claude-code.enable = true;
  
  # Atuin shell history server
  custom.atuin = {
    enable = true;
    openRegistration = false;
    jwtSecretFile = config.age.secrets.atuin-jwt-secret.path;
    databaseKeyFile = config.age.secrets.atuin-database-key.path;
  };

  # Agenix secret for Tailscale
  age.secrets.tailscale-authkey = {
    file = ../secrets/global/tailscale-authkey.age;
    owner = "root";
    group = "root";
    mode = "600";
  };

  # Trader Alpaca secrets
  age.secrets.trader-alpaca-paper-api-key = {
    file = ../secrets/trader/alpaca/paper-api-key.age;
    owner = "root";
    group = "root";
    mode = "600";
  };

  age.secrets.trader-alpaca-paper-api-secret = {
    file = ../secrets/trader/alpaca/paper-api-secret.age;
    owner = "root";
    group = "root";
    mode = "600";
  };

  # Atuin server secrets
  age.secrets.atuin-jwt-secret = {
    file = ../secrets/networking/atuin/jwt-secret.age;
    owner = "root";
    group = "root";
    mode = "600";
  };

  age.secrets.atuin-database-key = {
    file = ../secrets/networking/atuin/database-key.age;
    owner = "root";
    group = "root";
    mode = "600";
  };

  # Tailscale service configuration
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    authKeyFile = config.age.secrets.tailscale-authkey.path;
  };
  
  custom.create-ssh.enable = true;
  environment.systemPackages = [
    pkgs.cloudflared
    pkgs.tcpdump
    pkgs.qbittorrent-nox
    pkgs.sabnzbd
  ];

  #  Configure the firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 
      22 # SSH
      80 
      443 
      8080 # Traefik
      8089 # qBittorent
      8090 # Sabnzbd
      8888 # Atuin
      45036
      51820
      51822
      5000
    ];
  };

  custom.traefik = {
    enable = true;
  };

  custom.nuclio = {
    enable = true;
    dashboard.port = 8070;
    variables = {
      TEST = "test-123";
    };
  };

  # Enable Nuclio functions
  custom.nuclio-functions = {
    enable = true;
    functions.account-health = {
      handler = "handler:handler";
      runtime = "nodejs";
      description = "Acount health function";
      
      build = {
        baseImage = "node:18-alpine";
        
        # Use git repository source instead of inline code
        repository = {
          url = "http://192.168.50.243:3000/kyllswitch/trader";
          branch = "main";
          path = "functions/deploy/account-health";  # Work directory in repository (relative path)
          # headers = { Authorization = "token ghp_xxx"; };  # for private repos if needed
        };
      };
      
      triggers = {
        http = {
          kind = "http";
          maxWorkers = 2;
        };
      };
      
      env = [
        {
          name = "NODE_ENV";
          value = "production";
        }
        {
          name = "FUNCTION_NAME";
          value = "account-health";
        }
        {
          name = "ALPACA_BASE_URL";
          value = "https://paper-api.alpaca.markets";
        }
        {
          name = "ALPACA_API_KEY";
          valueFrom.secretPath = config.age.secrets.trader-alpaca-paper-api-key.path;
        }
        {
          name = "ALPACA_API_SECRET";
          valueFrom.secretPath = config.age.secrets.trader-alpaca-paper-api-secret.path;
        }
      ];
      
      resources = {
        limits = {
          memory = "128Mi";
          cpu = "100m";
        };
        requests = {
          memory = "64Mi";
          cpu = "50m";
        };
      };
      
      minReplicas = 1;
      maxReplicas = 3;
      targetCPU = 50;
    };

    functions.signal-generator = {
      handler = "handler:handler";
      runtime = "nodejs";
      description = "Signal generator function";
      
      build = {
        baseImage = "node:18-alpine";
        
        # Use git repopathsitory source instead of inline code
        repository = {
          url = "http://192.168.50.243:3000/kyllswitch/trader";
          branch = "main";
          path = "functions/deploy/signal-generator";
          # headers = { Authorization = "token ghp_xxx"; };  # for private repos
        };
      };
      
      triggers = {
        http = {
          kind = "http";
          maxWorkers = 2;
        };
      };
      
      env = [
        {
          name = "NODE_ENV";
          value = "production";
        }
        {
          name = "FUNCTION_NAME";
          value = "account-health";
        }
        {
          name = "ALPACA_BASE_URL";
          value = "https://paper-api.alpaca.markets";
        }
        {
          name = "ALPACA_API_KEY";
          valueFrom.secretPath = config.age.secrets.trader-alpaca-paper-api-key.path;
        }
        {
          name = "ALPACA_API_SECRET";
          valueFrom.secretPath = config.age.secrets.trader-alpaca-paper-api-secret.path;
        }
      ];
      
      resources = {
        limits = {
          memory = "128Mi";
          cpu = "100m";
        };
        requests = {
          memory = "64Mi";
          cpu = "50m";
        };
      };
      
      minReplicas = 1;
      maxReplicas = 3;
      targetCPU = 50;
    };

    functions.account-info = {
      handler = "handler:handler";
      runtime = "nodejs";
      description = "Account info";
      
      build = {
        baseImage = "node:18-alpine";
        
        # Use git repopathsitory source instead of inline code
        repository = {
          url = "http://192.168.50.243:3000/kyllswitch/trader";
          branch = "main";
          path = "functions/deploy/account-info";
          # headers = { Authorization = "token ghp_xxx"; };  # for private repos
        };
      };
      
      triggers = {
        http = {
          kind = "http";
          maxWorkers = 2;
        };
      };
      
      env = [
        {
          name = "NODE_ENV";
          value = "production";
        }
        {
          name = "FUNCTION_NAME";
          value = "account-health";
        }
        {
          name = "ALPACA_BASE_URL";
          value = "https://paper-api.alpaca.markets";
        }
        {
          name = "ALPACA_API_KEY";
          valueFrom.secretPath = config.age.secrets.trader-alpaca-paper-api-key.path;
        }
        {
          name = "ALPACA_API_SECRET";
          valueFrom.secretPath = config.age.secrets.trader-alpaca-paper-api-secret.path;
        }
      ];
      
      resources = {
        limits = {
          memory = "128Mi";
          cpu = "100m";
        };
        requests = {
          memory = "64Mi";
          cpu = "50m";
        };
      };
      
      minReplicas = 1;
      maxReplicas = 3;
      targetCPU = 50;
    };
  };

  users.groups.downloaders.members = [
    "kyle"
    "sabnzbd"
  ];

  custom.nfs = {
    enable = true;
    mounts = {
      media = {
        device = "192.168.50.154:/mnt/user/media";
        owner  = "downloaders";
        group  = "downloaders";
        mode   = "0775";
      };
    };
  };

  nixpkgs.config.allowUnfree = true;
  services.sabnzbd = {
    enable = true;
    openFirewall = true;
    group = "downloaders";
  };
}
