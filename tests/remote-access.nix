# Evaluate both bootstrap and deployed configurations without contacting the Pi.
let
  f = builtins.getFlake ("path:" + toString ../.);
  h = f.colmenaHive;
  check = c:
    assert c.services.tailscale.enable;
    assert c.services.tailscale.useRoutingFeatures == "none";
    assert c.services.tailscale.authKeyFile == null;
    assert c.users.users.kyle.linger;
    assert builtins.elem "default.target" c.systemd.user.services.herdr.wantedBy;
    assert c.systemd.user.services.herdr.serviceConfig.Restart == "on-failure";
    assert builtins.any (p: (p.pname or "") == "herdr") c.environment.systemPackages;
    true;
in { image = check f.nixosConfigurations.pi4-image.config; runtime = check h.nodes.pi4.config; }
