inheritWorkspaceArtifacts() {
    for art in $workspaceArtifacts;
    do
        inheritCargoArtifacts $art
    done
}

if [[ -n "${workspaceArtifacts-}" ]]; then
  postPatchHooks+=(inheritWorkspaceArtifacts)
else
    echo "workspaceArtifacts is not defined, will not reuse workspace artifacts"
fi
