let
  f = builtins.getFlake (toString ../.);
  c = f.colmenaHive.nodes.pi4.config;
  names = map (p: p.pname or "") c.environment.systemPackages;
in
assert builtins.elem "claude-code" names;
assert builtins.elem "codex" names;
assert builtins.elem "bun" names;
assert !(builtins.elem "hermes-agent" names);
assert builtins.isString c.system.build.toplevel.drvPath;
true
