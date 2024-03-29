{
  description = "Utility for building large cargo workspaces with crane";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.11";
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    nix-filter = {
      url = "github:numtide/nix-filter";
    };
  };

  outputs = inputs:

    let
      mkRustTarget = pkgs: pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
      buildWorkspace = args@{ pkgs, crane, src, craneInternal ? (crane.overrideToolchain (mkRustTarget pkgs)), ... }:
        (import ./lib {
          inherit pkgs crane craneInternal;
          nix-filter = inputs.nix-filter;
        }) {
          inherit src;
          args = (builtins.removeAttrs args [ "pkgs" "src" "crane" "craneInternal" ]);
        };
    in
    { inherit buildWorkspace; } // inputs.flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [ (import inputs.rust-overlay) ];
        };

        rustTarget = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
        crane = (inputs.crane.mkLib pkgs).overrideToolchain rustTarget;
      in
      rec {
        packages.example_workspace = buildWorkspace {
          inherit pkgs crane;
          src = ./example_workspace;
        };
        devShells.default = devShells.workspace2replace;
        devShells.workspace2replace = pkgs.mkShell {
          buildInputs = [ ];

          nativeBuildInputs = [
            rustTarget
          ];
        };
      }
    );
}
