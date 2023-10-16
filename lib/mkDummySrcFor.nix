{ pkgs, crane, nix-filter }: src: name: paths:
let
  onlyCrate = nix-filter.lib {
    root = src;
    include = paths;
  };
  dummy = crane.mkDummySrc { inherit src; pname = "name"; version = "unknown"; };
in
pkgs.runCommandLocal "dummy-src-for-${name}" { } ''
  echo "Writing dummy sources to $out"
  mkdir -p $out
  cp --recursive --no-preserve=mode,ownership ${dummy}/. -t $out

  echo "Overwriting with following paths: ${builtins.toString paths}"
  ${builtins.concatStringsSep "\n" (builtins.map (p: "rm -rf $out/${p}") paths)}

  echo "Copying in only sources from ${onlyCrate}"
  cp --recursive --no-preserve=mode,ownership ${onlyCrate}/. -t $out
''
