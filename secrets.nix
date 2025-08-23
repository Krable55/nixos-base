# Agenix secrets configuration
let
  # User keys (for editing secrets)
  kyle = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMh4QcZWNLqRMaj0D5iKH3FDZ8n/rKJR6XFLNQs7bWsa my key for nixos";
  
  # System host keys (for decryption on hosts)
  media-center = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGwrl0pqlsnMs9Cfxj9HGrGkuopqteMPxlMapyIAUgA1";
  builder = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKGBOr+16aLDiNF5sRQmTZ9AsHmnE9tVF1k8Qul6w3ho";
  networking = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINbKk9Z8Wdugwemk3Q3peHu5a56ow1LroxQslLp+xGCA";
  powerball = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDWEg9z+P1KtpqyXgAceCfAp6mbHmG0o/P2GGu4YZUsw";
  
  # Define which keys can edit/decrypt which secrets
  allSystems = [ media-center builder networking powerball ];
  allUsers = [ kyle ];
  
in {
  # Tailscale authkey - accessible by all systems
  "tailscale-authkey.age".publicKeys = allUsers ++ allSystems;
  
  # Test secret for verifying agenix works
  "test-secret.age".publicKeys = allUsers ++ allSystems;
  
  # Future secrets can be added here...
  # "example-secret.age".publicKeys = [ kyle media-center ];
}