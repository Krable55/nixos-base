# ZeroClaw's private OAuth maintenance is retired; do not restart it on apply.
let
  f = builtins.getFlake ("path:" + toString ../.);
  check = c:
    assert !(c.systemd.timers ? pi4-chatgpt-auth-refresh);
    assert !(c.systemd.services ? pi4-chatgpt-auth-refresh);
    assert !(builtins.any (p: (p.name or "") == "pi4-chatgpt-auth") c.environment.systemPackages);
    true;
in {
  runtime = check f.colmenaHive.nodes.pi4.config;
  image = check f.nixosConfigurations.pi4-image.config;
}
