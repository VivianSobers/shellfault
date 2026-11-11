{
  description = "shellfault toolchain and bash matrix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, zig-overlay }:
    let
      systems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      zigFallbackFor = pkgs: system:
        let
          source = {
            aarch64-darwin = {
              url = "https://ziglang.org/download/0.17.1/zig-aarch64-macos-0.17.1.tar.xz";
              hash = "sha256-dfG8eh6YUvF+yaDBiV92fE7FbUa8ioNJIO7OHQNZ3Y0=";
            };
            x86_64-linux = {
              url = "https://ziglang.org/download/0.17.1/zig-x86_64-linux-0.17.1.tar.xz";
              hash = "sha256-NYGGPjy8/Q/ODvxoLOfp6T2pZmipd3kdNWom0qfpsXo=";
            };
            aarch64-linux = {
              url = "https://ziglang.org/download/0.17.1/zig-aarch64-linux-0.17.1.tar.xz";
              hash = "sha256-oVRtVkbrGEQ3kY1mNcprdioOiJ6sCc73IO56HtP+d5U=";
            };
          }.${system};
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "zig";
          version = "0.17.1";
          src = pkgs.fetchurl source;
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            cp zig "$out/bin/zig"
            cp -R lib "$out/lib"
            if [ -d doc ]; then
              cp -R doc "$out/doc"
            fi
            runHook postInstall
          '';
        };

      mkPkgs = system:
        import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          bashMatrix = import ./nix/bash.nix {
            inherit pkgs system;
            lib = nixpkgs.lib;
          };
          zig =
            if pkgs ? zigpkgs && pkgs.zigpkgs ? "0.17.1"
            then pkgs.zigpkgs."0.17.1"
            else zigFallbackFor pkgs system;
        in
        {
          default = bashMatrix.bashes;
          bashes = bashMatrix.bashes;
          zig-0_17_1 = zig;
        });

      devShells = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          bashMatrix = import ./nix/bash.nix {
            inherit pkgs system;
            lib = nixpkgs.lib;
          };
          zig =
            if pkgs ? zigpkgs && pkgs.zigpkgs ? "0.17.1"
            then pkgs.zigpkgs."0.17.1"
            else zigFallbackFor pkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              zig
              pkgs.bats
              pkgs.shellcheck
              pkgs.jq
              bashMatrix.bashes
            ];
            SF_TEST_BASHES = bashMatrix.sfTestBashes;
          };
        });
    };
}
