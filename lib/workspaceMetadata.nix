{ pkgs, crane, extractMetadata }: src:
# We use our custom `extract_metadata` program to parse the output of `cargo metadata`. 
# It contains the necessary information about the build graph. That result is then saved in the store.
crane.mkCargoDerivation {
  cargoArtifacts = null;
  nativeBuildInputs = [ extractMetadata ];
  buildPhaseCargoCommand = ''
    extract_metadata Cargo.toml x86_64-unknown-linux-gnu > $out
  '';

  src = crane.mkDummySrc { inherit src; };
  pname = "metadata";
  version = "unknown";

  dontInstall = true;
}
