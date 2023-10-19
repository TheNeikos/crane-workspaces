{ runCommand
, crane
, bash
,
}:

runCommand "inheritWorkspaceArtifacts"
{
  propagatedBuildInputs = [
    crane.inheritCargoArtifactsHook
  ];
  strictDeps = true;
}
  ''
    mkdir -p $out/nix-support
    cp ${./inheritWorkspaceArtifactsHook.sh} $out/nix-support/setup-hook
    chmod +x $out/nix-support/setup-hook
    recordPropagatedDependencies
  ''
