{ pkgs, crane, extractMetadata }:
dummySrc: buildTarget: crane.mkCargoDerivation {
  cargoArtifacts = null;
  nativeBuildInputs = [ extractMetadata ];
  buildPhaseCargoCommand = ''
    extract_metadata Cargo.toml ${buildTarget} > $out
  '';

  src = dummySrc;
  pname = "metadata";
  version = "unknown";

  dontInstall = true;
}
