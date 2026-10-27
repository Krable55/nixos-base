{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.requests ps.pyjwt ps.cryptography ]);
in pkgs.writeShellApplication {
  name = "pi4-chatgpt-auth";
  runtimeInputs = [ python ];
  text = ''
    for arg in "$@"; do
      case "$arg" in
        --state-dir|--state-dir=*)
          printf '%s\n' 'State directory is fixed for this Pi registration.' >&2
          exit 64
          ;;
      esac
    done
    exec ${pkgs.coreutils}/bin/env -i \
      HOME=/var/lib/zeroclaw PATH=/run/current-system/sw/bin LANG=C.UTF-8 \
      ${python}/bin/python3 -B ${./chatgpt-auth/siwc.py} \
      --state-dir /var/lib/zeroclaw/siwc-test-state "$@"
  '';
  checkPhase = ''
    runHook preCheck
    ${pkgs.bash}/bin/bash -n "$target"
    "$target" --help >/dev/null
    result=0
    "$target" --state-dir=/tmp/disallowed status >/dev/null 2>&1 || result=$?
    test "$result" -eq 64
    PYTHONPATH=${./chatgpt-auth} ${python}/bin/python3 -B \
      -m unittest discover -v -s ${../tests/chatgpt-auth}
    runHook postCheck
  '';
}
