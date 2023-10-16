{ pkgs, crane, mergeTargets, workspaceMetadata, nix-filter }: { src, args ? { } }:
let
  doCheck = true;
  globalDummy = crane.mkDummySrc {
    inherit src;
    pname = "name";
    version = "unknown";
    extraDummyScript = ''
      find $out -iname "Cargo.toml" | while read TOML_FILE; do
        echo "Removing dev-dependencies from $TOML_FILE"
        chmod u+w $TOML_FILE
        # ${pkgs.dasel}/bin/dasel delete -s "dev-dependencies" -f "$TOML_FILE" 2>/dev/null || true
      done
      echo "Erased all dev-deps"
    '';
  };
  rawMetadata = workspaceMetadata globalDummy;
  metadata = builtins.fromTOML (builtins.readFile rawMetadata);
  cargoVendorDir = crane.vendorCargoDeps { inherit src; };
  workspaceDependencies = crane.buildDepsOnly
    (args // {
      inherit cargoVendorDir;
      dummySrc = globalDummy;
      pname = "workspace";
      version = "unknown";

      inherit doCheck;

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
      get_from_metadata = field: pkgs.runCommandLocal "${field}.toml" { buildInputs = [ pkgs.dasel ]; } ''
        dasel -r toml -f ${rawMetadata} 'workspace_member_info.${name}.${field}' > $out
      '';
      dep_manifest_path = metadata.workspace_member_info.${name}.manifest_path;
      normal_deps = get_from_metadata "dependencies";
      dev_deps = get_from_metadata "dev-dependencies";
      build_deps = get_from_metadata "build-dependencies";
      enabled_features = get_from_metadata "features";
      doReplaceDeps = ''
        # Replace all dependencies
        ALL_NORMAL_DEPS=$(cat ${normal_deps})
        echo "Patching 'dependencies' ${dep_manifest_path} with ${normal_deps}"
        ${pkgs.dasel}/bin/dasel put -r toml -t toml -v "$ALL_NORMAL_DEPS" -f ${dep_manifest_path} "dependencies"

        ALL_DEV_DEPS=$(cat ${dev_deps})
        echo "Patching 'dependencies' ${dep_manifest_path} with ${dev_deps}"
        ${pkgs.dasel}/bin/dasel put -r toml -t toml -v "$ALL_DEV_DEPS" -f ${dep_manifest_path} "dev-dependencies"

        ALL_BUILD_DEPS=$(cat ${build_deps})
        echo "Patching 'dependencies' ${dep_manifest_path} with ${build_deps}"
        ${pkgs.dasel}/bin/dasel put -r toml -t toml -v "$ALL_BUILD_DEPS" -f ${dep_manifest_path} "build-dependencies"
      '';
      doReplaceFeatures = ''
        # Replace all features
        ALL_FEATURES=$(cat ${enabled_features})
        echo "Patching ${dep_manifest_path} with ${enabled_features}"
        ${pkgs.dasel}/bin/dasel put -r toml -t toml -v "$ALL_FEATURES" -f ${dep_manifest_path} "features"
      '';
      doRemoveDevDeps = ''
        # Try removing dev-dependencies, if it doesn't exist just skip
        # echo "Removing dev dependencies for ${dep_manifest_path}"
        # ${pkgs.dasel}/bin/dasel delete -s "dev-dependencies" -f ${dep_manifest_path} 2>/dev/null || true
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
  workspaceMembers = builtins.mapAttrs
    (crate_name: crate_info:
      let
        cargoArtifacts = mergeTargets workspaceDependencies (pkgs.lib.getAttrs (builtins.map (n: n.name) crate_info.workspace_deps) workspaceMembers);
      in
      crane.mkCargoDerivation
        (args // {
          inherit cargoArtifacts cargoVendorDir;
          pname = crate_name;
          pnameSuffix = "-ws-build";
          version = "unknown";
          src = globalDummy;

          inherit doCheck;

          # Don't let crane install artifacts
          doInstallCargoArtifacts = false;

          nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
            crane.installFromCargoBuildLogHook
            pkgs.jq
            crane.removeReferencesToVendoredSourcesHook
          ];

          prePatch = installSourcesFor { names = ([ crate_name ] ++ (builtins.map (n: n.name) crate_info.workspace_deps)); preserveFirst = false; };

          preBuild = ''
            ${hashDirectory}/bin/hashDirectory target > pre_build_hashes
          '';
          buildPhaseCargoCommand = ''
            cargoBuildLog=$(mktemp cargoBuildLogXXXX.json)
            cargoWithProfile build -p ${crate_name} --message-format json-render-diagnostics >"$cargoBuildLog"
          '';
          checkPhaseCargoCommand = ''
            cargoWithProfile build --tests -p ${crate_name} --message-format json-render-diagnostics >"$cargoBuildLog"
          '';
          preInstall = ''
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

            echo "Copied $(wc -l < changed_files) files as artifacts"

            # Also copy any binaries we might have built

            installFromCargoBuildLog "$out" "$cargoBuildLog"

            runHook postInstall
          '';
        }) // { inherit cargoArtifacts; })
    metadata.workspace_member_info;
  debug = {
    inherit workspaceDependencies rawMetadata;

    workspace_structure = pkgs.lib.mapAttrs
      (k: v: {
        deps = v.workspace_deps;
        sources = mkSrc k;
        artifacts = workspaceMembers.${k}.cargoArtifacts;
      })
      metadata.workspace_member_info;
  };

in
crane.buildPackage
  (args // {
    inherit cargoVendorDir;
    cargoArtifacts = mergeTargets workspaceDependencies workspaceMembers;
    src = globalDummy;
    pname = "workspace";
    version = "unknown";

    prePatch = ''
      ${installSourcesFor { names = builtins.attrNames metadata.workspace_member_info; } }
    '';

    # CARGO_LOG = "cargo::core::compiler::fingerprint=trace";

    inherit doCheck;

    # We need to allow changing the lock file, but this is harmless, as we do not change the buildgraph
    cargoExtraArgs = "--offline";
  }) // workspaceMembers // { inherit debug; }
