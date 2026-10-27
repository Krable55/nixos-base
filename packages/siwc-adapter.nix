{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.requests ps.pyjwt ps.cryptography ps.tomli-w ]);
  zeroclawWeb = import ./zeroclaw-web.nix { inherit pkgs; };
  webDist = "${zeroclawWeb}/${zeroclawWeb.webDist}";
in pkgs.stdenvNoCC.mkDerivation {
  pname = "pi4-siwc-adapter";
  version = "1";
  src = ./siwc-adapter;
  dontBuild = true;
  installPhase = ''
    mkdir -p "$out/lib" "$out/bin"
    cp filtering_adapter.py provision.py pairing_state.py config.toml.in "$out/lib/"
    substituteInPlace "$out/lib/filtering_adapter.py" \
      --replace-fail '/home/kyll/Documents/pi-nix/nixos-base/packages/chatgpt-auth/siwc.py' '${./chatgpt-auth/siwc.py}'
    substituteInPlace "$out/lib/config.toml.in" \
      --replace-fail '@WEB_DIST_DIR@' '${webDist}'
    cat > "$out/bin/pi4-siwc-adapter" <<EOF
    #!${pkgs.runtimeShell}
    exec ${pkgs.coreutils}/bin/env -i HOME=/var/lib/zeroclaw PATH=${pkgs.coreutils}/bin LANG=C.UTF-8 SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${python}/bin/python3 -I "$out/lib/filtering_adapter.py" "\$@"
    EOF
    cat > "$out/bin/pi4-siwc-provision" <<EOF
    #!${pkgs.runtimeShell}
    exec ${pkgs.coreutils}/bin/env -i PATH=${pkgs.coreutils}/bin LANG=C.UTF-8 ${python}/bin/python3 -I "$out/lib/provision.py" "$out/lib/config.toml.in"
    EOF
    cat > "$out/bin/pi4-zeroclaw-pairing-state" <<EOF
    #!${pkgs.runtimeShell}
    exec ${pkgs.coreutils}/bin/env -i PATH=${pkgs.coreutils}/bin LANG=C.UTF-8 ${python}/bin/python3 -I "$out/lib/pairing_state.py" "\$@"
    EOF
    chmod 0555 "$out/bin/"*
  '';
  passthru = { inherit python zeroclawWeb webDist; };
}
