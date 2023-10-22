{ pkgs, crane, craneInternal, nix-filter }:

let
  # Handler crate
  callPackage = pkgs.lib.callPackageWith (pkgs // packages // { inherit nix-filter crane; });
  packages = {
    extractMetadata = craneInternal.buildPackage {
      src = ../extract_metadata;
    };
    workspaceMetadata = callPackage ./workspaceMetadata.nix { };
    mkDummySrcFor = callPackage ./mkDummySrcFor.nix { };
    mergeTargets = callPackage ./mergeTargets.nix { };
    buildWorkspace = callPackage ./buildWorkspace.nix { };
    inheritWorkspaceArtifacts = callPackage ./inheritWorkspaceArtifacts.nix { };
  };

in
packages.buildWorkspace
