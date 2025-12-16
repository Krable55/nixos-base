{ config, pkgs, lib, ... }:

let
  cfg = config.custom.k3s;
in {
  options.custom.k3s = {
    enable = lib.mkEnableOption "Enable K3s Kubernetes cluster";
    
    role = lib.mkOption {
      type = lib.types.str;
      default = "server";
      description = "K3s role: server or agent";
    };
    
    serverAddr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "K3s server address (for agents)";
    };
    
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to file containing K3s token";
    };
    
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra flags to pass to K3s";
    };
    
    disableComponents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "traefik" ];  # Disable K3s Traefik since we have external one
      description = "K3s components to disable";
    };
  };
  
  config = lib.mkIf cfg.enable {
    # Enable K3s service
    services.k3s = {
      enable = true;
      role = cfg.role;
      extraFlags = cfg.extraFlags ++ (map (comp: "--disable=${comp}") cfg.disableComponents);
    } // lib.optionalAttrs (cfg.serverAddr != null) {
      serverAddr = cfg.serverAddr;
    } // lib.optionalAttrs (cfg.tokenFile != null) {
      tokenFile = cfg.tokenFile;
    };
    
    # Install required packages
    environment.systemPackages = with pkgs; [
      k3s
      kubectl
      arkade
    ];
    
    # Open required firewall ports for K3s
    networking.firewall = {
      allowedTCPPorts = [
        6443  # K3s API server
        10250 # kubelet
      ];
      allowedUDPPorts = [
        8472  # flannel VXLAN
      ];
    };
    
    # Ensure proper system configuration for K3s
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.ipv4.ip_forward" = 1;
    };
    
    # Enable required kernel modules
    boot.kernelModules = [ "br_netfilter" ];
  };
}