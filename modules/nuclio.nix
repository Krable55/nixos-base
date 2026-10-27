{ config, pkgs, lib, ... }:

let
  cfg = config.custom.nuclio;
in {
  options.custom.nuclio = {
    enable = lib.mkEnableOption "Enable Nuclio serverless platform on Kubernetes";
    
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "nuclio";
      description = "Kubernetes namespace for Nuclio components";
    };
    
    functionNamespace = lib.mkOption {
      type = lib.types.str;
      default = "nuclio-functions";
      description = "Kubernetes namespace for Nuclio functions";
    };
    
    dashboard = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8070;
        description = "Port for Nuclio dashboard";
      };
      
      resources = lib.mkOption {
        type = lib.types.attrs;
        default = {
          requests = { memory = "64Mi"; cpu = "50m"; };
          limits = { memory = "128Mi"; cpu = "100m"; };
        };
        description = "Resource limits for Nuclio dashboard";
      };
    };
    
    controller = {
      resources = lib.mkOption {
        type = lib.types.attrs;
        default = {
          requests = { memory = "128Mi"; cpu = "100m"; };
          limits = { memory = "256Mi"; cpu = "200m"; };
        };
        description = "Resource limits for Nuclio controller";
      };
    };
    
    registry = {
      secretName = lib.mkOption {
        type = lib.types.str;
        default = "registry-credentials";
        description = "Name of Kubernetes secret containing registry credentials";
      };
      
      pushPullUrl = lib.mkOption {
        type = lib.types.str;
        default = "docker.io";
        description = "Registry URL for pushing and pulling function images";
      };
    };
    
    disablePrometheus = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable Prometheus to save resources";
    };
    
    version = lib.mkOption {
      type = lib.types.str;
      default = "1.13.10";
      description = "Nuclio version to deploy";
    };
    
    extraHelmValues = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Additional Helm values for Nuclio chart";
    };
  };
  
  config = lib.mkIf cfg.enable {
    # Ensure helm and kubectl are available
    environment.systemPackages = with pkgs; [
      kubernetes-helm
      kubectl
    ];
    
    # SystemD service to clean up OpenFaaS before installing Nuclio
    systemd.services.openfaas-cleanup = {
      description = "Clean up OpenFaaS resources before Nuclio installation";
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      wantedBy = [ "nuclio-install.service" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
      };
      
      environment = {
        KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
        PATH = lib.mkForce (lib.makeBinPath (with pkgs; [ kubectl coreutils gnugrep ]));
      };
      
      script = ''
        # Wait for K3s to be ready
        until kubectl get nodes --request-timeout=5s >/dev/null 2>&1; do
          echo "Waiting for K3s to be ready..."
          sleep 10
        done
        
        # Remove OpenFaaS namespaces and resources if they exist
        echo "Cleaning up OpenFaaS resources..."
        
        # Delete OpenFaaS functions namespace
        kubectl delete namespace openfaas-fn --ignore-not-found=true --timeout=60s || true
        
        # Delete OpenFaaS namespace  
        kubectl delete namespace openfaas --ignore-not-found=true --timeout=60s || true
        
        # Wait for namespaces to be fully deleted
        while kubectl get namespace openfaas >/dev/null 2>&1; do
          echo "Waiting for openfaas namespace to be deleted..."
          sleep 5
        done
        
        while kubectl get namespace openfaas-fn >/dev/null 2>&1; do
          echo "Waiting for openfaas-fn namespace to be deleted..."
          sleep 5
        done
        
        echo "OpenFaaS cleanup completed"
      '';
    };
    
    # SystemD service to install Nuclio via Helm
    systemd.services.nuclio-install = {
      description = "Install Nuclio via Helm";
      after = [ "openfaas-cleanup.service" "k3s.service" "network-online.target" ];
      wants = [ "openfaas-cleanup.service" "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        Restart = "on-failure";
        RestartSec = "30s";
      };
      
      environment = {
        KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
        PATH = lib.mkForce (lib.makeBinPath (with pkgs; [ kubernetes-helm kubectl coreutils ]));
      };
      
      script = let
        baseHelmValues = {
          controller = {
            image = {
              repository = "quay.io/nuclio/controller";
              tag = "${cfg.version}-amd64";
            };
            resources = cfg.controller.resources;
          };
          
          dashboard = {
            # Disable dashboard since it's incompatible with containerd/K3s
            enabled = false;
          };

          rbac = {
            create = true;
          };
          
          crd = {
            create = true;
          };

          # Global platform configuration
          platform = {
            kind = "kube";
            containerBuilderConfiguration = {
              kind = "kaniko";
              busyBoxImage = "busybox:stable";
              kanikoImage = "gcr.io/kaniko-project/executor:v1.23.2";
              kanikoImagePullPolicy = "IfNotPresent";
              jobPrefix = "kanikojob";
              jobDeletionTimeout = 1800000000000; # 30 minutes in nanoseconds
              defaultRegistryCredentialsSecretName = cfg.registry.secretName;
              defaultBaseRegistryURL = cfg.registry.pushPullUrl;
              insecurePushRegistry = false;
              insecurePullRegistry = false;
            };
          };
          
          # Resource-optimized settings for 4GB server
          registry = {
            secretName = cfg.registry.secretName;
            pushPullUrl = cfg.registry.pushPullUrl;
          };
        };
        
        prometheusSettings = lib.optionalAttrs cfg.disablePrometheus {
          # Disable Prometheus to save memory
          prometheus = {
            enabled = false;
          };
        };
        
        helmValues = lib.recursiveUpdate 
          (baseHelmValues // prometheusSettings)
          cfg.extraHelmValues;
        
        valuesFile = pkgs.writeText "nuclio-values.yaml" (lib.generators.toYAML {} helmValues);
      in ''
        # Wait for K3s to be ready
        until kubectl get nodes --request-timeout=5s >/dev/null 2>&1; do
          echo "Waiting for K3s to be ready..."
          sleep 10
        done
        
        # Add Nuclio Helm repository
        echo "Adding Nuclio Helm repository..."
        helm repo add nuclio https://nuclio.github.io/nuclio/charts || true
        helm repo update
        
        # Create namespaces
        echo "Creating Nuclio namespaces..."
        kubectl create namespace ${cfg.namespace} --dry-run=client -o yaml | kubectl apply -f -
        kubectl create namespace ${cfg.functionNamespace} --dry-run=client -o yaml | kubectl apply -f -
        
        # Create a basic registry secret (can be updated later)
        echo "Creating registry secret..."
        kubectl create secret docker-registry ${cfg.registry.secretName} \
          --namespace=${cfg.namespace} \
          --docker-server=${cfg.registry.pushPullUrl} \
          --docker-username=dummy \
          --docker-password=dummy \
          --docker-email=dummy@example.com \
          --dry-run=client -o yaml | kubectl apply -f - || true
          
        # Install Nuclio via Helm
        echo "Installing Nuclio via Helm..."
        helm upgrade --install nuclio \
          --namespace=${cfg.namespace} \
          --values=${valuesFile} \
          --version=0.20.10 \
          nuclio/nuclio
        
        # Wait for Nuclio controller to be ready
        echo "Waiting for Nuclio controller to be ready..."
        kubectl wait --namespace=${cfg.namespace} \
          --for=condition=ready pod \
          --selector=nuclio.io/app=controller \
          --timeout=300s
        
        echo "Nuclio installation completed successfully"
        echo "Controller is ready. Dashboard is disabled (incompatible with containerd)."
        echo "Use 'nuctl' CLI or kubectl to manage functions."
      '';
    };
    
    # Dashboard is disabled, no firewall ports needed
  };
}