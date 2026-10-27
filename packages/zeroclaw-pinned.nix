# Exact retained upstream full-feature v0.8.6 build, not nixpkgs' version.
# Source rev c473221313341a853e04122f93bb9bd26b5e6c47; upstream flake's
# packages.aarch64-linux.zeroclaw with its own locked nixpkgs/fenix.
# These build artifacts intentionally remain outside Git; this is a host-specific
# prerequisite, not a pending task to vendor them into this repository.
# Both store paths must already be retained/transferred. Intentionally fail
# evaluation if absent rather than silently initiating another Rust build.
{
  type = "derivation";
  name = "zeroclaw-0.8.6";
  system = "aarch64-linux";
  outPath = builtins.storePath /nix/store/adkc7f6i4b46gaf1296ir59whcjva4cl-zeroclaw-0.8.6;
  drvPath = builtins.storePath /nix/store/r4k0xpgaa1fl2bxnf634dr65zccxg9z3-zeroclaw-0.8.6.drv;
  outputName = "out";
}
