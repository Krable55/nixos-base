{ config, pkgs, lib, ... }:

let
  cfg = config.custom.nuclio;
in {
  options.custom.nuclio = {
    enable = lib.mkEnableOption "Enable Nuclio serverless platform on Docker";
    
    dashboard = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8070;
        description = "Port for Nuclio dashboard";
      };
    };

    variables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str; # e.g. { FOO = "bar"; BAZ = "qux"; }
      default = {};
      description = "Map of environment variables to inject (name -> value).";
    };
    
    registry = {
      pushPullUrl = lib.mkOption {
        type = lib.types.str;
        default = "docker.io";
        description = "Registry URL for pushing and pulling function images";
      };
    };
    
    version = lib.mkOption {
      type = lib.types.str;
      default = "1.13.10";
      description = "Nuclio version to deploy";
    };
    
    nodeVersion = lib.mkOption {
      type = lib.types.str;
      default = "18";
      description = "Node.js version for JavaScript functions (supports optional chaining and nullish coalescing)";
    };
  };
  
  config = lib.mkIf cfg.enable {
    # Enable Docker
    virtualisation.docker = {
      enable = true;
      enableOnBoot = true;
    };
    
    # Ensure Docker and Docker Compose are available
    environment.systemPackages = with pkgs; [
      docker
      docker-compose
    ];
    
    # Create nuclio directories for persistence
    systemd.tmpfiles.rules = [
      "d /var/lib/nuclio 0755 root root -"
      "d /var/lib/nuclio/function-data 0755 root root -"
      "d /var/lib/nuclio/platform-config 0755 root root -"
      "d /var/lib/nuclio/registry-cache 0755 root root -"
    ];
    
    # SystemD service to run Nuclio via Docker Compose
    systemd.services.nuclio-docker = {
      description = "Nuclio serverless platform via Docker";
      after = [ "docker.service" "network-online.target" ];
      wants = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        Restart = "on-failure";
        RestartSec = "30s";
        WorkingDirectory = "/var/lib/nuclio";
      };
      
      environment = {
        PATH = lib.mkForce (lib.makeBinPath (with pkgs; [ docker docker-compose coreutils ]));
      };
      
      script = let
        dockerComposeFile = pkgs.writeText "nuclio-docker-compose.yaml" ''
          version: '3.7'

          services:
            nuclio-controller:
              image: quay.io/nuclio/controller:${cfg.version}-amd64
              container_name: nuclio-controller
              restart: unless-stopped
              volumes:
                - /var/run/docker.sock:/var/run/docker.sock
                - /var/lib/nuclio/function-data:/home/nuclio
                - /var/lib/nuclio/platform-config:/etc/nuclio
                - /var/lib/nuclio/registry-cache:/tmp/nuclio-registry-cache
              environment:
                - NUCLIO_NAMESPACE=nuclio
                - NUCLIO_CONTAINER_BUILDER_KIND=docker
                - NUCLIO_REGISTRY_URL=${cfg.registry.pushPullUrl}
                # Fix networking: Use docker0 interface IP for function containers
                - NUCLIO_PLATFORM_CONFIG_KUBE_DEFAULT_FUNCTION_NODE_SELECTOR=
                - NUCLIO_PLATFORM_CONFIG_KUBE_DEFAULT_FUNCTION_SERVICE_TYPE=NodePort
                # Configure Node.js runtime version
                - NUCLIO_NODEJS_RUNTIME_IMAGE=node:${cfg.nodeVersion}-alpine
                ${lib.concatStringsSep "\n                " (lib.mapAttrsToList (n: v: "- ${n}=${v}") cfg.variables)}
              
              networks:
                - nuclio

            nuclio-dashboard:
              image: quay.io/nuclio/dashboard:${cfg.version}-amd64
              container_name: nuclio-dashboard
              restart: unless-stopped
              # Use host networking so dashboard can reach function ports on host
              network_mode: host
              volumes:
                - /var/run/docker.sock:/var/run/docker.sock
                - /var/lib/nuclio/function-data:/home/nuclio
                - /var/lib/nuclio/platform-config:/etc/nuclio
                - /var/lib/nuclio/registry-cache:/tmp/nuclio-registry-cache
              environment:
                - NUCLIO_NAMESPACE=nuclio
                - NUCLIO_CONTAINER_BUILDER_KIND=docker
                - NUCLIO_REGISTRY_URL=${cfg.registry.pushPullUrl}
                - NUCLIO_DASHBOARD_DEPLOYMENT_NAME=nuclio-dashboard
                # Configure networking for proper function URL generation
                - NUCLIO_DASHBOARD_EXTERNAL_IP_ADDRESSES=127.0.0.1
                - NUCLIO_DASHBOARD_FUNCTION_DEFAULT_HTTP_INGRESS_HOST=127.0.0.1
                # Dashboard will bind to host port directly
                - NUCLIO_DASHBOARD_LISTEN_ADDRESS=:${toString cfg.dashboard.port}
                # Extra config variables for nuclio
              depends_on:
                - nuclio-controller

            # Helper container to configure Docker network for functions
            nuclio-local-storage-reader:
              image: gcr.io/iguazio/alpine:3.20
              container_name: nuclio-local-storage-reader
              restart: unless-stopped
              command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
              networks:
                - nuclio

          networks:
            nuclio:
              driver: bridge
              ipam:
                config:
                  - subnet: 172.20.0.0/16
                    gateway: 172.20.0.1
        '';

        # Platform configuration file to ensure functions use correct network
        platformConfigFile = pkgs.writeText "platform.yaml" ''
          kind: docker
          webAdmin:
            enabled: true
            listenAddress: ":8081"
          healthCheck:
            enabled: true
            listenAddress: ":8082"
          logger:
            sinks:
              stdout:
                kind: stdout
            system:
              - level: debug
                sink: stdout
            functions:
              - level: debug
                sink: stdout
          containerBuilderConfiguration:
            kind: docker
            defaultRegistryCredentialsSecretName: ""
            defaultBaseRegistryURL: "${cfg.registry.pushPullUrl}"
            defaultOnbuildRegistryURL: "quay.io"
            # Functions will be accessible via host networking
            defaultFunctionContainerNetworkName: "nuclio_nuclio"
          # Configure Node.js runtime version for modern JavaScript features
          runtimeConfiguration:
            nodejs:
              image: "node:${cfg.nodeVersion}-alpine"
              baseImage: "node:${cfg.nodeVersion}-alpine"
          # Configure function invocation for host networking
          functionConfig:
            spec:
              triggers:
                http:
                  attributes:
                    ingresses:
                      "0":
                        host: "127.0.0.1"
        '';
      in ''
        # Copy Docker Compose file
        cp ${dockerComposeFile} /var/lib/nuclio/docker-compose.yaml

        # Copy platform config
        cp ${platformConfigFile} /var/lib/nuclio/platform.yaml

        # Start Nuclio services
        echo "Starting Nuclio services via Docker Compose..."
        cd /var/lib/nuclio
        docker-compose up -d

        # Wait for services to be ready
        echo "Waiting for Nuclio controller to be ready..."
        timeout 300 bash -c 'until docker exec nuclio-controller curl -f http://localhost:8082/ready >/dev/null 2>&1; do sleep 5; done' || true

        echo "Waiting for Nuclio dashboard to be ready..."
        timeout 300 bash -c 'until docker exec nuclio-dashboard curl -f http://localhost:8082/ready >/dev/null 2>&1; do sleep 5; done' || true

        echo "Configuring Docker network for function containers..."
        # Ensure the nuclio network exists and is properly configured
        docker network inspect nuclio_nuclio >/dev/null 2>&1 || docker network create nuclio_nuclio --subnet 172.20.0.0/16

        echo "Nuclio installation completed successfully"
        echo "Dashboard available at: http://localhost:${toString cfg.dashboard.port}"
        echo "Functions will be deployed on the nuclio_nuclio network for proper connectivity"
      '';
      
      preStop = ''
        cd /var/lib/nuclio || exit 0
        docker-compose down || true
      '';
    };
    
    # Open firewall for Nuclio dashboard
    networking.firewall.allowedTCPPorts = [ cfg.dashboard.port ];
    
    # Add docker group for managing containers
    users.groups.docker = {};
  };
}