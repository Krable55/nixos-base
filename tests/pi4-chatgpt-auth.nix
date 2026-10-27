let
  f = builtins.getFlake ("path:" + toString ../.);
  h = f.colmenaHive;
  c = h.nodes.pi4.config;
  image = f.nixosConfigurations.pi4-image.config;
  lib = f.inputs.nixpkgs-pi.lib;
in {
  runtime =
    assert lib.assertMsg (c.systemd.timers ? pi4-chatgpt-auth-refresh)
      "Pi4 must have a persistent daily ChatGPT credential refresh timer";
    let
      service = c.systemd.services.pi4-chatgpt-auth-refresh;
      s = service.serviceConfig;
      t = c.systemd.timers.pi4-chatgpt-auth-refresh;
    in
    assert t.timerConfig.OnCalendar == "daily";
    assert t.timerConfig.Persistent;
    assert t.wantedBy == [ "timers.target" ];
    assert t.timerConfig.Unit == "pi4-chatgpt-auth-refresh.service";
    assert s.Type == "oneshot";
    assert s.User == "zeroclaw" && s.Group == "zeroclaw";
    assert s.UMask == "0077" && s.NoNewPrivileges;
    assert s.ProtectSystem == "strict" && s.ProtectHome;
    assert s.PrivateTmp && s.PrivateDevices;
    assert s.ReadWritePaths == [ "/var/lib/zeroclaw/siwc-test-state" ];
    assert s.CapabilityBoundingSet == [];
    assert s.Restart == "no";
    assert s.TimeoutStartSec == "5min";
    assert builtins.match ".*/bin/pi4-chatgpt-auth refresh" s.ExecStart != null;
    assert builtins.elem "network-online.target" service.after;
    assert builtins.any (p: (p.name or "") == "pi4-chatgpt-auth") c.environment.systemPackages;
    true;
  imageHasNoAccountBoundTimer =
    assert !(image.systemd.timers ? pi4-chatgpt-auth-refresh);
    true;
}
