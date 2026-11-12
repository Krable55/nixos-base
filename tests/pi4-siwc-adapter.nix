# Deployment regression: ZeroClaw and its adapter must stay retired.
# The locked legacy account/data are retained; this does not erase credentials.
let
  f = builtins.getFlake ("path:" + toString ../.);
  c = f.colmenaHive.nodes.pi4.config;
  check = config:
    assert builtins.all (name: !(builtins.hasAttr name config.systemd.services)) [
      "pi4-zeroclaw" "pi4-zeroclaw-pairing-state"
      "pi4-siwc-adapter" "pi4-siwc-runtime"
    ];
    assert !(config.systemd.paths ? pi4-zeroclaw-pairing-state);
    assert !(config.users.users ? zeroclaw-agent);
    assert !(builtins.elem 18766 config.networking.firewall.allowedTCPPorts);
    assert !(builtins.elem 42617 config.networking.firewall.allowedTCPPorts);
    assert !(builtins.any (p: builtins.match ".*(zeroclaw|siwc-adapter).*" (p.name or "") != null) config.environment.systemPackages);
    true;
in {
  runtime = check c;
  image = check f.nixosConfigurations.pi4-image.config;
  # Force the same top-level evaluation needed by a Colmena apply.
  system = c.system.build.toplevel.drvPath;
}
