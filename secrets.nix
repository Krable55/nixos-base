# Agenix secrets configuration
let
  # User keys (for editing secrets)
  kyle = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMh4QcZWNLqRMaj0D5iKH3FDZ8n/rKJR6XFLNQs7bWsa my key for nixos";
  
  # System host keys (for decryption on hosts)
  media-center = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGwrl0pqlsnMs9Cfxj9HGrGkuopqteMPxlMapyIAUgA1";
  builder = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKGBOr+16aLDiNF5sRQmTZ9AsHmnE9tVF1k8Qul6w3ho";
  networking = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINbKk9Z8Wdugwemk3Q3peHu5a56ow1LroxQslLp+xGCA";
  powerball = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDWEg9z+P1KtpqyXgAceCfAp6mbHmG0o/P2GGu4YZUsw";
  trader = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMzlakBngVBQTzqOkj+N+81Il3xpbtPnBqC9Iu+Ckozd";

  # Define which keys can edit/decrypt which secrets
  allSystems = [ media-center builder networking powerball trader ];
  allUsers = [ kyle ];
  
  # Helper function to create secrets for a specific service on a host
  mkServiceSecrets = hostName: host: service: secretNames:
    builtins.listToAttrs (map (name: {
      name = "secrets/${hostName}/${service}/${name}.age";
      value = { publicKeys = allUsers ++ [ host ]; };
    }) secretNames);
  
  # Helper function for service secrets available to all hosts
  mkGlobalSecrets = service: secretNames:
    builtins.listToAttrs (map (name: {
      name = "secrets/global/${service}-${name}.age";
      value = { publicKeys = allUsers ++ allSystems; };
    }) secretNames);
  
in 
# Combine all secret definitions
(mkGlobalSecrets "tailscale" [ "authkey" ]) //
(mkGlobalSecrets "test" [ "secret" ]) //
(mkServiceSecrets "networking" networking "faasd" [ "basic-auth-password" ]) //
(mkServiceSecrets "trader" trader "alpaca" [ 
  "paper-api-key"
  "paper-api-secret"
]) //
(mkServiceSecrets "networking" networking "atuin" [
  "jwt-secret"
  "database-key"
]) //
(mkServiceSecrets "media-center" media-center "kometa" [
  "plex-token"
  "mdblist-apikey"
  "tmdb-apikey"
]) //
(mkServiceSecrets "trader" trader "supabase" [ 
  "admin-password" 
  "postgres-password"
  "jwt-secret"
  "anon-key" 
  "service-role-key"
  "secret-key-base"
  "vault-enc-key"
]) //
{
  # Cross-host secrets (needed for Nuclio functions on networking host)
  "secrets/trader/alpaca/paper-api-key.age".publicKeys = allUsers ++ [ networking trader ];
  "secrets/trader/alpaca/paper-api-secret.age".publicKeys = allUsers ++ [ networking trader ];
  "secrets/trader/supabase/anon-key.age".publicKeys = allUsers ++ [ networking trader ];
  
  # Future secrets can be added here...
  # Manual overrides if needed:
  # "custom-secret.age".publicKeys = [ kyle media-center ];
}