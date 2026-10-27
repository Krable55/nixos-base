{ lib, stdenvNoCC, fetchurl }:
stdenvNoCC.mkDerivation {
  pname = "herdr";
  version = "0.9.5";
  # Official statically linked ARM64 release; no foreign dynamic loader required.
  src = fetchurl {
    url = "https://github.com/herdrdev/herdr/releases/download/v0.9.5/herdr-linux-aarch64";
    sha256 = "17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c";
  };
  dontUnpack = true;
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/herdr"
    runHook postInstall
  '';
  meta = {
    description = "Terminal workspace manager for AI coding agents";
    homepage = "https://herdr.dev";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-linux" ];
    mainProgram = "herdr";
  };
}
