{ pkgs }:

let
  dashboard = import ../../packages/zeroclaw-web.nix { inherit pkgs; };
in
pkgs.runCommand "zeroclaw-web-assets-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 ${./check-assets.py} ${dashboard}/share/zeroclaw-web > "$out"
  ''
