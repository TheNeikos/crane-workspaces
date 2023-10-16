{ pkgs, crane }: default_derivation: derivations:
let
  inherit (pkgs.lib) getOutput;
  getArtifacts = getOutput "artifacts";
  name = "merged-targets-${builtins.concatStringsSep "-" (["default"] ++ (pkgs.lib.mapAttrsToList (name: _: name) derivations))}";
in
pkgs.runCommandLocal name { nativeBuildInputs = [ crane.inheritCargoArtifactsHook pkgs.rsync ]; } ''
  mkdir -p $out
  cd $out
  echo "Copying default workspace artifacts"
  # export doNotLinkInheritedArtifacts=1

  inheritCargoArtifacts ${default_derivation}

  ${builtins.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (name: drv: ''
      echo "Copying artifacts from ${name}: ${getArtifacts drv}"
      inheritCargoArtifacts ${getArtifacts drv}
    '') derivations)}
''
