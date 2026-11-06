let
  f = builtins.getFlake (toString ../.);
  c = f.colmenaHive.nodes.pi4.config;
  container = c.virtualisation.oci-containers.containers.paperclip;
in
assert c.virtualisation.oci-containers.backend == "podman";
assert container.ports == [ "192.168.50.238:3100:3100" ];
assert container.environment.PAPERCLIP_AUTH_PUBLIC_BASE_URL == "http://192.168.50.238:3100";
assert container.environment.PAPERCLIP_DEPLOYMENT_MODE == "authenticated";
assert builtins.match ".*@sha256:[0-9a-f]+" container.image != null;
assert container.volumes == [ "paperclip-data:/paperclip" ];
assert builtins.elem "paperclip-secrets.service" c.systemd.services.podman-paperclip.requires;
assert builtins.elem 3100 c.networking.firewall.allowedTCPPorts;
assert c.systemd.services.podman-paperclip.serviceConfig.TimeoutStartSec == "30min";
assert builtins.isString c.system.build.toplevel.drvPath;
true
