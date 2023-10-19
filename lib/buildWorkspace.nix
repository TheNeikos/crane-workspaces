{ pkgs, crane, mergeTargets, inheritWorkspaceArtifacts, workspaceMetadata, nix-filter }: { src, args ? { } }:
let
  globalDummy = crane.mkDummySrc {
    inherit src;
    pname = "name";
    version = "unknown";
    extraDummyScript = ''
      find $out -iname "Cargo.toml" | while read TOML_FILE; do
        echo "Removing dev-dependencies from $TOML_FILE"
        chmod u+w $TOML_FILE
        ${pkgs.dasel}/bin/dasel delete -s "dev-dependencies" -f "$TOML_FILE" 2>/dev/null || true
      done
      echo "Erased all dev-deps"
    '';
  };
  rawMetadata = workspaceMetadata globalDummy;
  metadata = builtins.fromTOML (builtins.readFile rawMetadata);
  get_dependencies_for = name: rawMetadata: pkgs.runCommandLocal "deps.toml" { buildInputs = [ pkgs.dasel ]; } ''
    dasel -r toml -f ${rawMetadata} 'workspace_member_info.${name}.dependencies' > $out
  '';
  get_features_for = name: rawMetadata: pkgs.runCommandLocal "features.toml" { buildInputs = [ pkgs.dasel ]; } ''
    dasel -r toml -f ${rawMetadata} 'workspace_member_info.${name}.features' > $out
  '';
  cargoVendorDir = crane.vendorCargoDeps { inherit src; };
  workspaceDependencies = crane.buildDepsOnly
    (args // {
      inherit cargoVendorDir;
      dummySrc = globalDummy;
      pname = "workspace";
      version = "unknown";

      doCheck = false;

      # We need to allow changing the lock file, but this is harmless, as we do not change the buildgraph
      cargoExtraArgs = "--offline";
    });
  hashDirectory = pkgs.writeShellApplication {
    name = "hashDirectory";
    runtimeInputs = [ pkgs.fd ];
    text = ''
      fd --base-directory "$1" -I --hidden --type f --strip-cwd-prefix -x sha1sum {} | awk '{ print $2 ":" $1 }' | sort
    '';
  };
  mkSrc = name:
    let
      crate_info = metadata.workspace_member_info.${name};
      current_path = builtins.dirOf crate_info.manifest_path;
      currentCrate = nix-filter.lib {
        root = src;
        include = [ current_path ];
      };
    in
    pkgs.runCommandLocal "workspace-src-${name}" { } ''
      echo "Writing sources to $out"
      mkdir -p $out

      echo "Copying in only sources from ${currentCrate}"
      cp -rv "${currentCrate}" --no-target-directory "$out"

      chmod -R u+w $out

      echo "Patching toml files"
      cd $out
      ${patchCargoToml { inherit name; }}

      echo "Done!"
    '';
  patchCargoToml = { name, replaceDeps ? true, replaceFeatures ? true, removeDevDeps ? true }:
    let
      dep_all_crates_with_features = get_dependencies_for name rawMetadata;
      dep_all_features_with_crates = get_features_for name rawMetadata;
      dep_manifest_path = metadata.workspace_member_info.${name}.manifest_path;
      doReplaceDeps = ''
        # Replace all dependencies
        ALL_DEPS=$(cat ${dep_all_crates_with_features})
        echo "Patching ${dep_manifest_path} with ${dep_all_crates_with_features}"
        ${pkgs.dasel}/bin/dasel put -r toml -t toml -v "$ALL_DEPS" -f ${dep_manifest_path} "dependencies"
      '';
      doReplaceFeatures = ''
        # Replace all features
        ALL_FEATURES=$(cat ${dep_all_features_with_crates})
        echo "Patching ${dep_manifest_path} with ${dep_all_features_with_crates}"
        ${pkgs.dasel}/bin/dasel put -r toml -t toml -v "$ALL_FEATURES" -f ${dep_manifest_path} "features"
      '';
      doRemoveDevDeps = ''
        # Try removing dev-dependencies, if it doesn't exist just skip
        echo "Removing dev dependencies for ${dep_manifest_path}"
        ${pkgs.dasel}/bin/dasel delete -s "dev-dependencies" -f ${dep_manifest_path} 2>/dev/null || true
      '';
    in
    (pkgs.lib.optionalString replaceDeps doReplaceDeps)
    + (pkgs.lib.optionalString replaceFeatures doReplaceFeatures)
    + (pkgs.lib.optionalString removeDevDeps doRemoveDevDeps);
  installSourcesFor = { names, preserveFirst ? true }:
    let
      sources = map mkSrc names;
      paths = map (n: builtins.dirOf metadata.workspace_member_info.${n}.manifest_path) names;
      mainSource = builtins.head sources;
    in
    ''
      echo "Overwriting with following paths: ${builtins.concatStringsSep ", " paths}"
      ${builtins.concatStringsSep "\n" (builtins.map (p: "rm -rf ${p}; echo 'Removed ${p}'") paths)}

      echo "Installing sources from ${mainSource}" 
      cp -r "${mainSource}" --no-target-directory . \
        ${pkgs.lib.optionalString preserveFirst "--preserve=timestamps"} \
        --no-preserve=ownership

      ${builtins.concatStringsSep "\n" (builtins.map (source: ''
        echo "Installing sources from ${source}" 
        cp -r "${source}" --no-target-directory . --preserve=timestamps --no-preserve=ownership
      '') (builtins.tail sources))}
    '';
  callWorkspacePackage = pkgs.lib.callPackageWith workspaceMembers;
  workspaceMembers = (builtins.mapAttrs
    (crate_name: crate_info:
      let
        crate_deps = (builtins.map (n: n.name) crate_info.workspace_deps);
        drv = members: crane.mkCargoDerivation
          (args // {
            inherit cargoVendorDir;
            pname = crate_name;
            pnameSuffix = "-ws-build";
            version = "unknown";

            src = globalDummy;
            cargoArtifacts = workspaceDependencies;

            # Don't let crane install artifacts
            doInstallCargoArtifacts = false;

            nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
              crane.installFromCargoBuildLogHook
              pkgs.jq
              crane.removeReferencesToVendoredSourcesHook
              inheritWorkspaceArtifacts
            ];
            workspaceArtifacts = map (pkgs.lib.getOutput "artifacts") (pkgs.lib.attrVals crate_deps members);

            prePatch = ''
              ${
                installSourcesFor {
                  names = ([ crate_name ] ++ crate_deps);
                  preserveFirst = false;
                }
              }
            '';
            preBuild = ''
              ${hashDirectory}/bin/hashDirectory target > pre_build_hashes
            '';
            buildPhaseCargoCommand = ''
              cargoBuildLog=$(mktemp cargoBuildLogXXXX.json)
              cargoWithProfile build -p ${crate_name} --message-format json-render-diagnostics >"$cargoBuildLog"
            '';
            postBuild = ''
              ${hashDirectory}/bin/hashDirectory target > post_build_hashes
            '';

            outputs = [ "out" "artifacts" ];

            # CARGO_LOG = "cargo::core::compiler::fingerprint=trace";

            installPhase = ''
              runHook preInstall

              # Copy any artifacts we produced

              mkdir -p $artifacts

              (diff pre_build_hashes post_build_hashes || true) |\
                awk '/> (.*):.*/ {split($2, pieces, ":"); print "target/" pieces[1];}' > changed_files

              cat changed_files \
                | xargs --no-run-if-empty -n1 dirname \
                | sort -u \
                | (cd "$artifacts"; xargs --no-run-if-empty mkdir -p)

              cat changed_files \
                | xargs -P $NIX_BUILD_CORES -I '##{}##' cp "##{}##" "$artifacts/##{}##"

              cat > $artifacts/inherit_artifacts <<EOF
                #! ${pkgs.bash}/bin/bash
                echo "You should be getting ${crate_name} artifacts!"
              EOF
              chmod +x $artifacts/inherit_artifacts

              # Also copy any binaries we might have built

              installFromCargoBuildLog "$out" "$cargoBuildLog"

              runHook postInstall
            '';
          });

      in
      callWorkspacePackage (pkgs.lib.setFunctionArgs drv (builtins.listToAttrs (builtins.map (d: { name = "${d}"; value = true; }) crate_deps))) { })
    metadata.workspace_member_info) // {
    _workspace =
      let
        workspaceMembers = (builtins.attrNames metadata.workspace_member_info);
        drv = members:
          crane.buildPackage
            (args // {
              inherit cargoVendorDir;
              src = globalDummy;
              cargoArtifacts = workspaceDependencies;
              workspaceArtifacts = map (pkgs.lib.getOutput "artifacts") (pkgs.lib.attrVals workspaceMembers members);
              nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
                inheritWorkspaceArtifacts
              ];
              pname = "workspace";
              version = "unknown";

              prePatch = ''
                ${installSourcesFor { names = builtins.attrNames metadata.workspace_member_info; } }
              '';

              # CARGO_LOG = "cargo::core::compiler::fingerprint=trace";

              doCheck = false;

              # We need to allow changing the lock file, but this is harmless, as we do not change the buildgraph
              cargoExtraArgs = "--offline";

              passthru = {
                inherit workspaceMembers;
              };
            });
      in
      callWorkspacePackage (pkgs.lib.setFunctionArgs drv (builtins.listToAttrs (builtins.map (d: { name = "${d}"; value = true; }) (builtins.attrNames metadata.workspace_member_info)))) { };
  };
  debug = {
    inherit workspaceDependencies;

    workspace_structure = pkgs.lib.mapAttrs
      (k: v: {
        sources = mkSrc k;
      })
      metadata.workspace_member_info;
  };

in
workspaceMembers._workspace
