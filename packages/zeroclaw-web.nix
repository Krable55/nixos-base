# Official ZeroClaw v0.8.6 dashboard bundle.
#
# This packages trusted official prebuilt assets from the fixed-hash GitHub
# release archive; it does not locally rebuild or independently attest them.
# The tag resolves to the reviewed revision, whose workflow runs `cargo web
# build` from web/package-lock.json before injecting web/dist into each release
# archive, but those observations are not cryptographic build-provenance proof.
# Reusing the archive avoids both a Rust rebuild (the generated OpenAPI bindings
# require Rust) and ARM/QEMU npm work. Source and lock assertions pin the
# reviewed metadata and prevent reliance on an ambient store path.
{ pkgs }:

let
  version = "0.8.6";
  rev = "c473221313341a853e04122f93bb9bd26b5e6c47";

  source = pkgs.fetchFromGitHub {
    owner = "zeroclaw-labs";
    repo = "zeroclaw";
    inherit rev;
    hash = "sha256-6w2xwCeV4U957wiOt3B9iY+ayA90Q1YzdaSCXvEJNS4=";
  };

  # web/dist is produced once and copied unchanged into every target archive;
  # choose the native workstation archive to avoid executing foreign binaries.
  releaseArchive = pkgs.fetchurl {
    url = "https://github.com/zeroclaw-labs/zeroclaw/releases/download/v${version}/zeroclaw-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-eeuHmR872Rro5u8C14szlhzR2HSVHf01EjTGkqApekc=";
  };
in
pkgs.runCommand "zeroclaw-web-${version}"
  {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.gnugrep ];
    passthru = {
      inherit version rev source releaseArchive;
      webDist = "share/zeroclaw-web";
      packageLockSha256 = "e46b4dc22e923b8d753ff0ddaba346160b22f86d5b629650cfe6552dd85e9091";
    };
    meta = {
      description = "Official ZeroClaw ${version} web dashboard assets";
      homepage = "https://github.com/zeroclaw-labs/zeroclaw";
      license = with pkgs.lib.licenses; [ mit asl20 ];
      platforms = pkgs.lib.platforms.all;
    };
  }
  ''
    actual_lock="$(${pkgs.coreutils}/bin/sha256sum ${source}/web/package-lock.json | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
    test "$actual_lock" = "e46b4dc22e923b8d753ff0ddaba346160b22f86d5b629650cfe6552dd85e9091"
    ${pkgs.gnugrep}/bin/grep -Fq 'run: cargo web build' \
      ${source}/.github/workflows/release-stable-manual.yml

    mkdir unpack
    tar -xzf ${releaseArchive} -C unpack
    test -s unpack/web/dist/index.html
    test -d unpack/web/dist/assets

    mkdir -p "$out/share/zeroclaw-web"
    cp -R unpack/web/dist/. "$out/share/zeroclaw-web/"
  ''
