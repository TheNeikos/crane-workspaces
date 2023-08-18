# crane-workspaces

This flake is an extension to the very useful [crane](https://github.com/ipetkov/crane) library.

It provides a single method, called `buildWorkspace` which allows more
efficient building of cargo workspaces using crane. The ultimate goal of this
repository is to be somehow merged into the crane library. Until it passes that
level of quality, development will occur here.

## Usage

1. Add this flake to your inputs
2. Call `buildWorkspace`:

```nix
crane-workspaces.buildWorkspace { inherit pkgs crane; src = ./. };
```

Where `pkgs` is an instance of the nixpkgs repo, and `crane` is a result of `crane.mkLib`.

These are provided as inputs, due to the fact that it is easier this way to control the respective toolchains.

3. The output is a derivation as if you've used `crane.buildPackage`. It will
   include all the binaries that your workspace would produce.

## How it works

Fundamentally it does the following:

- It reads the workspace metadata using `cargo metadata`

This includes all the necessary information for the rest of the process. 
Notably: All the used dependencies by all workspace members, and the
workspace-wide features used for these dependencies.

- Then, for each workspace member, we produce a single `crane.cargoBuild`
  derivation and give in _only_ the required sources. These are composed of the
  sources of the workspace member itself as well as any local dependencies.
  Then, some patching occurs to make sure that even if building the members in
  isolation, global features are enabled. This ensures that all dependencies
  are built with the same features, allowing re-use of previous builds. Then,
  the build outputs (rust intermediary files) are cached and re-used for
  subsequent builds and as dependencies of other workspace members. This
  reflects the dependency graph of your workspace, and thanks to nix gets built
  in the correct order and even in parallel.

- Finally a single output `crane.buildPackage` is constructed, using the
  artifact outputs of all workspace members. This takes no time at all, as the
  packages have already been built! Finally, crane copies the executables and
  we're done.

