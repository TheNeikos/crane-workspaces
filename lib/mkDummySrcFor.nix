{ pkgs, crane, nix-filter }: src: name: paths:
let
  dummy = crane.mkDummySrc { inherit src; pname = "name"; version = "unknown"; };
  # A filter that removes everything except the given workspace_paths
  onlyCrate = nix-filter.lib {
    root = src;
    include = paths;
  };
in
# The result of this derivation is a folder structure derived from the original source, 
# except it only contains the sources of the workspace member we are currently building, 
# and all its local dependencies.
pkgs.runCommandLocal "dummy-src-for-${name}" { } ''
  mkdir -p $out
  cp --recursive --no-preserve=mode,ownership ${dummy}/. -t $out
  echo "Overwriting with following paths: ${builtins.toString paths}"
  ${builtins.concatStringsSep "\n" (builtins.map (p: "rm -rf $out/${p}") paths)}
  cp --recursive --no-preserve=mode,ownership ${onlyCrate}/. -t $out
''
