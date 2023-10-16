{ pkgs, crane, extractMetadata }:
dummySrc: crane.mkCargoDerivation {
  cargoArtifacts = null;
  nativeBuildInputs = [ extractMetadata ];
  buildPhaseCargoCommand = ''
    extract_metadata Cargo.toml x86_64-unknown-linux-gnu > $out
  '';

  src = dummySrc;
  pname = "metadata";
  version = "unknown";

  dontInstall = true;
}
