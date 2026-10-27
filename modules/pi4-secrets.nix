# Runtime only: the ciphertext is bound to this installed Pi's SSH host key.
# Do not import into the reusable SD image; a fresh host needs re-encryption.
{ inputs, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops = {
    age = {
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      keyFile = null;
      generateKey = false;
    };
    gnupg.sshKeyPaths = [];
    validateSopsFiles = true;

    secrets.op-service-account-token = {
      sopsFile = ../secrets/pi4.yaml;
      format = "yaml";
      key = "op_service_account_token";
      path = "/run/secrets/op-service-account-token";
      owner = "root";
      group = "root";
      mode = "0400";
      neededForUsers = false;
      # No consumer is deployed yet. Rotation must not start an agent implicitly.
      restartUnits = [];
      reloadUnits = [];
    };
  };
}
