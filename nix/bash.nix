{ pkgs, lib, system }:
let
  mkBash = spec:
    pkgs.stdenv.mkDerivation {
      pname = spec.name;
      version = spec.version;
      src = pkgs.fetchurl {
        url = "https://ftp.gnu.org/gnu/bash/bash-${spec.version}.tar.gz";
        hash = spec.hash;
      };
      NIX_CFLAGS_COMPILE = "-std=gnu89 -Wno-error";
      configureFlags = [
        "--without-bash-malloc"
        "--with-curses"
      ];
      nativeBuildInputs = [ pkgs.bison ];
      buildInputs = [ pkgs.ncurses ];
      # Old releases trip -Werror=format-security and race in parallel make.
      hardeningDisable = [ "format" ];
      enableParallelBuilding = lib.versionAtLeast spec.version "4.0";
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin"
        cp bash "$out/bin/${spec.name}"
        runHook postInstall
      '';
    };

  specs =
    (lib.optionals (!pkgs.stdenv.hostPlatform.isDarwin) [
      {
        name = "bash-3.2";
        version = "3.2.57";
        hash = "sha256-P6na+F6/NQaPCQzlEoPd7rPHXrW8cLGkp8sFhov+BqQ=";
      }
    ])
    ++ [
      {
        name = "bash-4.4";
        version = "4.4.18";
        hash = "sha256-YE2e7F5O1f0hgO5E3XVt3KkuC2qkIXu6srYic4AxfyM=";
      }
      {
        name = "bash-5.1";
        version = "5.1.16";
        hash = "sha256-W6wXIY05EYNFINrRPNH4WrlE4cCa4aulWQa+H4GS9Vg=";
      }
      {
        name = "bash-5.2";
        version = "5.2.37";
        hash = "sha256-lZmyLs0dV4etfTt78MWfMSszltHigRdd0fikAU2mIf8=";
      }
      {
        name = "bash-5.3";
        version = "5.3";
        hash = "sha256-DVzYaWX4aaJs9k9Lcb57lvkKO6iz104n6OnZ1VUPMbo=";
      }
    ];

  built = map (spec: { inherit spec; drv = mkBash spec; }) specs;
  builtPaths = map (item: "${item.drv}/bin/${item.spec.name}") built;
in
{
  bashes = pkgs.symlinkJoin {
    name = "shellfault-bashes";
    paths = map (item: item.drv) built;
  };

  sfTestBashes = lib.concatStringsSep ":" (
    builtPaths
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ "/bin/bash" ]
  );
}
