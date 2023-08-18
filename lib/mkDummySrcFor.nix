{ pkgs, crane, nix-filter }: src: name: paths:
let
  onlyCrateSrc = workspace_paths: source: nix-filter.lib {
    root = source;
    include = workspace_paths;
  };
  dummy = crane.mkDummySrc { inherit src; pname = "name"; version = "unknown"; };
  onlyCrate = onlyCrateSrc paths src;
in
pkgs.runCommandLocal "dummy-src-for-${name}" { } ''
  mkdir -p $out
  cp --recursive --no-preserve=mode,ownership ${dummy}/. -t $out
  echo "Overwriting with following paths: ${builtins.toString paths}"
  ${builtins.concatStringsSep "\n" (builtins.map (p: "rm -rf $out/${p}") paths)}
  cp --recursive --no-preserve=mode,ownership ${onlyCrate}/. -t $out
''
