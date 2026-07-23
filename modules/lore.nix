{ config, pkgs, lib, ... }:

let
  cfg = config.custom.lore;

  loreSrc = pkgs.fetchFromGitHub {
    owner = "EpicGames";
    repo = "lore";
    rev = "826ad5d20ff4f5814101c946df127cef8253ada3";
    hash = "sha256-B/it6qh9VaGzH1QDdW1296hqxoMyjvwk9Z7ER590n4I=";
  };

  # fetchCargoVendor (nixpkgs default) uses fetch-cargo-vendor-util which hits
  # the crates.io API endpoint — that returns 403 for yanked crates. Running
  # `cargo vendor` directly uses cargo's native HTTP client which sends the
  # correct user agent and can download yanked crates from the CDN.
  loreCargoDeps = pkgs.stdenvNoCC.mkDerivation {
    name = "loreserver-cargo-deps";
    src = loreSrc;
    nativeBuildInputs = with pkgs; [ cargo cacert git ];
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = "sha256-6q6HYnrKFTwmo8j2w/mOe13xbm38Xi/rpeBkiTt2e8o=";
    buildPhase = ''
      export HOME=$(mktemp -d)
      export CARGO_HOME=$(mktemp -d)
      cargo vendor $out
    '';
    dontInstall = true;
    dontFixup = true;
  };

  loreserver = pkgs.rustPlatform.buildRustPackage {
    pname = "loreserver";
    version = "unstable-2026-07-22";
    src = loreSrc;
    # vendor/quinn-proto is a [patch.crates-io] path dep inside the lore source.
    # Putting registry crates in the same directory as quinn-proto makes cargo apply
    # directory-source semantics to the patch, requiring a .cargo-checksum.json that
    # doesn't exist. Use a separate cargo-vendor/ so quinn-proto stays outside the
    # directory-source root and is resolved as a plain path dep (no checksum needed).
    cargoVendorDir = "cargo-vendor";
    postUnpack = ''
      cp -rT ${loreCargoDeps} $sourceRoot/cargo-vendor
    '';
    cargoBuildFlags = [ "--package" "lore-server" ];
    doCheck = false;
    nativeBuildInputs = [ pkgs.pkg-config pkgs.protobuf ];
    # lore's .cargo/config.toml sets these; cargoSetupHook overwrites that file
    # with the vendored-sources config, so we must pass them as env instead.
    RUSTFLAGS = "--cfg tokio_unstable --cfg uuid_unstable";
  };
in {
  options.custom.lore = {
    enable = lib.mkEnableOption "Lore VCS server";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/lore";
      description = "Root directory for Lore's immutable and mutable object stores";
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/lore";
      description = "Directory for Lore TOML configuration overrides";
    };

    grpcPort = lib.mkOption {
      type = lib.types.port;
      default = 41337;
      description = "Port for gRPC (TCP) and QUIC (UDP) client traffic";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 41339;
      description = "Port for the HTTP health check endpoint (GET /health_check)";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "RUST_LOG level for the server";
    };

    tlsEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use persistent TLS certificates for QUIC instead of an ephemeral
        self-signed cert. When true the host must declare age.secrets.lore-tls-cert
        and age.secrets.lore-tls-key pointing to the PEM files.
      '';
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra LORE__* environment variables passed to the server";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.lore = {
      isSystemUser = true;
      group = "lore";
      home = cfg.dataDir;
      createHome = false;
    };
    users.groups.lore = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir}           0750 lore lore -"
      "d ${cfg.dataDir}/immutable 0750 lore lore -"
      "d ${cfg.dataDir}/mutable   0750 lore lore -"
      "d ${cfg.configDir}         0750 lore lore -"
    ];

    systemd.services.lore = {
      description = "Lore VCS server";
      after = [ "network.target" ] ++ lib.optional cfg.tlsEnabled "agenix.service";
      wants = lib.optional cfg.tlsEnabled "agenix.service";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "lore";
        Group = "lore";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${loreserver}/bin/loreserver";
        Restart = "always";
        RestartSec = "5s";
        Environment = [
          "LORE_CONFIG_PATH=${cfg.configDir}"
          "LORE_ENV=production"
          "RUST_LOG=${cfg.logLevel}"
          "LORE__IMMUTABLE_STORE__LOCAL__PATH=${cfg.dataDir}/immutable"
          "LORE__MUTABLE_STORE__LOCAL__PATH=${cfg.dataDir}/mutable"
        ] ++ lib.mapAttrsToList (n: v: "${n}=${v}") cfg.env;
      };
      preStart = lib.optionalString cfg.tlsEnabled ''
        cat > ${cfg.configDir}/local.toml <<EOF
        [server.quic.certificate]
        cert_file = "${config.age.secrets.lore-tls-cert.path}"
        pkey_file  = "${config.age.secrets.lore-tls-key.path}"
        EOF
        chmod 644 ${cfg.configDir}/local.toml
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.grpcPort cfg.httpPort ];
    networking.firewall.allowedUDPPorts = [ cfg.grpcPort ];
  };
}
