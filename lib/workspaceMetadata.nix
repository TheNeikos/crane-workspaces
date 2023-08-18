{ pkgs, crane, extractMetadata }:
let
  disableAutoDiscovery = pkgs.writeShellScript "disableAutoDiscovery" ''
    CARGOTOMLS=$()
  '';
in
src: crane.mkCargoDerivation {
  cargoArtifacts = null;
  nativeBuildInputs = [ extractMetadata ];
  buildPhaseCargoCommand = ''
    ${disableAutoDiscovery}
    extract_metadata Cargo.toml x86_64-unknown-linux-gnu > $out
  '';

  src = crane.mkDummySrc { inherit src; };
  pname = "metadata";
  version = "unknown";

  dontInstall = true;
}
