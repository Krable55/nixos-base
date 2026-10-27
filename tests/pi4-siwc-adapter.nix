let
  f = builtins.getFlake ("path:" + toString ../.);
  h = f.colmenaHive;
  c = h.nodes.pi4.config;
  image = f.nixosConfigurations.pi4-image.config;
  lib = f.inputs.nixpkgs-pi.lib;
  u = c.users.users.zeroclaw-agent;
  a = c.systemd.services.pi4-siwc-adapter;
  z = c.systemd.services.pi4-zeroclaw;
  pairingPath = c.systemd.paths.pi4-zeroclaw-pairing-state;
  pairingSnapshot = c.systemd.services.pi4-zeroclaw-pairing-state;
  r = c.systemd.services.pi4-siwc-runtime;
  adapterPackage = import ../packages/siwc-adapter.nix { pkgs = h.nodes.pi4.pkgs; };
  zeroclawWeb = import ../packages/zeroclaw-web.nix { pkgs = h.nodes.pi4.pkgs; };
  webDist = "${zeroclawWeb}/${zeroclawWeb.webDist}";
  packageContract = h.nodes.pi4.pkgs.runCommand "pi4-siwc-adapter-package-contract"
    {
      nativeBuildInputs = [ h.nodes.pi4.pkgs.gnugrep ];
      exportReferencesGraph = [ "adapter-closure" adapterPackage ];
    }
    ''
      test "$(${h.nodes.pi4.pkgs.gnugrep}/bin/grep -Fxc 'web_dist_dir = "${webDist}"' ${adapterPackage}/lib/config.toml.in)" -eq 1
      ! ${h.nodes.pi4.pkgs.gnugrep}/bin/grep -Fq '@WEB_DIST_DIR@' ${adapterPackage}/lib/config.toml.in
      ${h.nodes.pi4.pkgs.gnugrep}/bin/grep -Fxq '${zeroclawWeb}' adapter-closure
      test -s ${webDist}/index.html
      test -d ${webDist}/assets
      touch "$out"
    '';
in
assert lib.assertMsg (c.systemd.services ? pi4-siwc-adapter) "missing SIWC adapter integration";
assert u.isSystemUser && u.group == "zeroclaw-agent" && u.extraGroups == [];
assert u.home == "/var/lib/zeroclaw-agent" && u.homeMode == "0700";
assert u.hashedPassword == "!" && u.openssh.authorizedKeys.keys == [] && !u.linger;
assert builtins.match ".*/nologin" (toString u.shell) != null;
assert a.serviceConfig.User == "zeroclaw" && z.serviceConfig.User == "zeroclaw-agent";
assert z.serviceConfig.InaccessiblePaths == [ "/var/lib/zeroclaw" ];
assert z.serviceConfig.ProtectProc == "invisible";
assert a.serviceConfig.LimitCORE == 0 && z.serviceConfig.LimitCORE == 0;
assert r.serviceConfig.User == "root" && r.serviceConfig.RemainAfterExit;
assert builtins.elem "pi4-siwc-runtime.service" a.requires;
assert builtins.elem "pi4-siwc-adapter.service" z.bindsTo;
assert lib.assertMsg (c.systemd.paths ? pi4-zeroclaw-pairing-state) "missing pairing-state path activation";
assert lib.assertMsg (c.systemd.services ? pi4-zeroclaw-pairing-state) "missing pairing-state snapshot service";
assert pairingPath.pathConfig.PathChanged == "/run/zeroclaw-agent/config.toml";
assert pairingPath.pathConfig.Unit == "pi4-zeroclaw-pairing-state.service";
assert pairingPath.after == [ "pi4-zeroclaw.service" ];
assert pairingPath.requires == [ "pi4-zeroclaw.service" ];
assert pairingPath.partOf == [ "pi4-zeroclaw.service" ];
assert pairingPath.wantedBy == [ "multi-user.target" ];
assert pairingPath.unitConfig.DefaultDependencies == false;
assert pairingPath.unitConfig.Conflicts == "shutdown.target";
assert pairingPath.unitConfig.Before == "shutdown.target";
assert pairingSnapshot.after == [ "pi4-zeroclaw.service" ];
assert pairingSnapshot.requires == [ "pi4-zeroclaw.service" ];
assert pairingSnapshot.serviceConfig.Type == "oneshot";
assert pairingSnapshot.serviceConfig.User == "zeroclaw-agent" && pairingSnapshot.serviceConfig.Group == "zeroclaw-agent";
assert pairingSnapshot.serviceConfig.RuntimeMaxSec == "10s";
assert pairingSnapshot.serviceConfig.TimeoutStartSec == "10s";
assert pairingSnapshot.serviceConfig.TimeoutStopSec == "10s";
assert pairingSnapshot.serviceConfig.UMask == "0077";
assert pairingSnapshot.serviceConfig.ReadWritePaths == [ "/var/lib/zeroclaw-agent" "/run/zeroclaw-agent" ];
assert pairingSnapshot.serviceConfig.StandardOutput == "null" && pairingSnapshot.serviceConfig.StandardError == "null";
assert builtins.match ".*pi4-zeroclaw-pairing-snapshot" (toString z.serviceConfig.ExecStopPost) != null;
assert z.serviceConfig.Restart == "on-failure" && z.serviceConfig.MemoryMax == "1G" && z.serviceConfig.TasksMax == 128;
assert a.serviceConfig.ReadWritePaths == [ "/var/lib/zeroclaw/siwc-test-state" ];
assert c.systemd.services.pi4-chatgpt-auth-refresh.serviceConfig.User == "zeroclaw";
assert !(image.systemd.services ? pi4-siwc-adapter) && !(image.users.users ? zeroclaw-agent);
assert !(builtins.elem 18766 c.networking.firewall.allowedTCPPorts);
assert !(builtins.elem 42617 c.networking.firewall.allowedTCPPorts);
assert adapterPackage.zeroclawWeb == zeroclawWeb;
assert adapterPackage.webDist == webDist;
{
  passed = true;
  adapterExec = a.serviceConfig.ExecStart;
  agentExec = z.serviceConfig.ExecStart;
  provisionExec = r.serviceConfig.ExecStart;
  adapterPackage = adapterPackage.drvPath;
  zeroclawWeb = zeroclawWeb.drvPath;
  webDist = webDist;
  packageContract = packageContract.drvPath;
  zeroclaw = (import ../packages/zeroclaw-pinned.nix).outPath;
  system = c.system.build.toplevel.drvPath;
}
