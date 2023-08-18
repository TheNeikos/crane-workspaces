{ pkgs, crane, nix-filter }:

let
  # Compose all the different functions together
  callPackage = pkgs.lib.callPackageWith (pkgs // packages // { inherit nix-filter crane; });
  packages = {
    extractMetadata = crane.buildPackage {
      src = ../extract_metadata;
    };
    workspaceMetadata = callPackage ./workspaceMetadata.nix { };
    mkDummySrcFor = callPackage ./mkDummySrcFor.nix { };
    mergeTargets = callPackage ./mergeTargets.nix { };
    buildWorkspace = callPackage ./buildWorkspace.nix { };
  };

in
packages.buildWorkspace
