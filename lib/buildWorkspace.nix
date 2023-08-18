{ pkgs, crane, mergeTargets, mkDummySrcFor, workspaceMetadata }: src:
let
  metadata = workspaceMetadata src;
  parsedMetadata = builtins.fromTOML (builtins.readFile metadata);
  getDependenciesFor = crate_name: metadata: pkgs.runCommandLocal "deps.toml" { buildInputs = [ pkgs.dasel ]; } ''
    dasel -r toml -f ${metadata} 'workspace_member_info.${crate_name}.dependencies' > $out
  '';
  workspaceArtifacts = crane.buildDepsOnly {
    inherit src;
    pname = "workspace";
    version = "unknown";
  };
  patchCargoToml = name:
    let
      dep_all_crates_with_features = getDependenciesFor name metadata;
      dep_manifest_path = parsedMetadata.workspace_member_info.${name}.manifest_path;
    in
    ''
      ALL_DEPS=$(cat ${dep_all_crates_with_features})
      echo "Patching ${dep_manifest_path}"
      ${pkgs.dasel}/bin/dasel put -r toml -t toml -v "$ALL_DEPS" -f ${dep_manifest_path} "dependencies"
    '';
  workspaceMembers = builtins.mapAttrs
    (crate_name: crate_info:
      let
        crateSrc = mkDummySrcFor src crate_name ([ (builtins.dirOf crate_info.manifest_path) ] ++ crate_info.workspace_path_dependencies);
        all_crates_with_features = getDependenciesFor crate_name metadata;
        cargoArtifacts = mergeTargets workspaceArtifacts (pkgs.lib.getAttrs crate_info.workspace_deps workspaceMembers);
      in
      crane.cargoBuild {
        inherit cargoArtifacts;
        pname = crate_name;
        version = "unknown";
        src = crateSrc;
        doInstallCargoArtifacts = true;

        postPatch = ''
          ALL_DEPS=$(cat ${all_crates_with_features})
          echo "Patching ${crate_info.manifest_path}"
          ${pkgs.dasel}/bin/dasel put -r toml -t toml -v "$ALL_DEPS" -f ${crate_info.manifest_path} "dependencies"
          ${
            builtins.concatStringsSep "\n" (builtins.map patchCargoToml crate_info.workspace_deps)
          }
        '';

        cargoExtraArgs = "-v -p ${crate_name}";
      })
    parsedMetadata.workspace_member_info;
  finalArtifacts = mergeTargets workspaceArtifacts workspaceMembers;
  finalSrc = pkgs.runCommandLocal "final-workspace-source" { } (
    let dummy_src = mkDummySrcFor src "workspace" (pkgs.lib.mapAttrsToList (_: info: (builtins.dirOf info.manifest_path)) parsedMetadata.workspace_member_info);
    in
    ''
      mkdir -p $out
      echo "Copying final dummy sources"
      cp --recursive --no-preserve=mode,ownership ${dummy_src}/. -t $out
      cd $out
      echo "Patching Cargo.tomls"
      ${builtins.concatStringsSep "\n" (builtins.map patchCargoToml (builtins.attrNames parsedMetadata.workspace_member_info))}
    ''
  );

in
crane.buildPackage {
  cargoArtifacts = finalArtifacts;
  src = finalSrc;
  pname = "workspace";
  version = "unknown";

  doNotLinkInheritedArtifacts = "true";

  cargoExtraArgs = "-vvv";
}
