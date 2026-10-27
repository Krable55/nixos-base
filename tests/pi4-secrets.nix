# Evaluation only: never decrypts secrets or contacts the Pi.
let
  f = builtins.getFlake ("path:" + toString ../.);
  h = f.colmenaHive;
  c = h.nodes.pi4.config;
  image = f.nixosConfigurations.pi4-image.config;
  lib = f.inputs.nixpkgs-pi.lib;
in {
  runtime =
    assert lib.assertMsg (c ? sops.secrets.op-service-account-token)
      "Pi4 must provision the root-only OP bootstrap secret";
    let s = c.sops.secrets.op-service-account-token; in
    assert builtins.attrNames c.sops.secrets == [ "op-service-account-token" ];
    assert s.owner == "root" && s.group == "root" && s.mode == "0400";
    assert s.path == "/run/secrets/op-service-account-token";
    assert s.key == "op_service_account_token" && s.format == "yaml";
    assert builtins.hashFile "sha256" s.sopsFile ==
      builtins.hashFile "sha256" ../secrets/pi4.yaml;
    assert !s.neededForUsers && s.restartUnits == [] && s.reloadUnits == [];
    assert c.sops.age.sshKeyPaths == [ "/etc/ssh/ssh_host_ed25519_key" ];
    assert c.sops.age.keyFile == null && !c.sops.age.generateKey;
    assert c.sops.gnupg.sshKeyPaths == [] && c.sops.gnupg.home == null;
    assert c.sops.validateSopsFiles;
    true;
  imageHasNoHostBoundSecret =
    assert !(image ? sops.secrets.op-service-account-token);
    true;
}
