let
  f = builtins.getFlake ("path:" + toString ../.);
  h = f.colmenaHive;
  check = c:
    let u = c.users.users.zeroclaw; in
    assert u.isSystemUser;
    assert u.group == "zeroclaw";
    assert u.extraGroups == [];
    assert u.home == "/var/lib/zeroclaw";
    assert u.homeMode == "0700";
    assert u.hashedPassword == "!";
    assert u.openssh.authorizedKeys.keys == [];
    assert builtins.match ".*/nologin" (toString u.shell) != null;
    assert !u.linger;
    assert builtins.elem "d /var/lib/zeroclaw/.zeroclaw 0700 zeroclaw zeroclaw -" c.systemd.tmpfiles.rules;
    assert builtins.elem "d /var/lib/zeroclaw/.zeroclaw/workspace 0700 zeroclaw zeroclaw -" c.systemd.tmpfiles.rules;
    true;
in { image = check f.nixosConfigurations.pi4-image.config; runtime = check h.nodes.pi4.config; }
