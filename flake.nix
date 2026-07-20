{
  description = "flake for ddf";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };

        zig = pkgs.zigpkgs."0.16.0";
        zls = pkgs.zls_0_16;
        # this is needed because this affects libc
        zigTarget =
          if pkgs.stdenv.isLinux then
            "${pkgs.stdenv.hostPlatform.system}-gnu"
          else
            pkgs.stdenv.hostPlatform.system;

        # This is so that notcurses doesn't crash when launched from tmux
        notcursesPatched = pkgs.notcurses.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            (pkgs.fetchpatch {
              url = "https://github.com/dankamongmen/notcurses/pull/2926/changes/9e436185ff2da838e3d5f2d119c192537cbfab53.patch";
              hash = "sha256-1EBbQZghAyvXks5KClStgZ1VXd4MGKm4NwkSXQOluXw=";
            })
          ];
        });

        treeSitterDeps = with pkgs; [
          tree-sitter
          tree-sitter-grammars.tree-sitter-c
          tree-sitter-grammars.tree-sitter-zig
          tree-sitter-grammars.tree-sitter-rust
        ];

        librariesToInclude = [
          notcursesPatched
          pkgs.ncurses
          pkgs.libunistring
          pkgs.libdeflate
          pkgs.glibc
          pkgs.glibc
          pkgs.stdenv.cc.cc.lib
        ]
        ++ treeSitterDeps;

        binName = "ddf";
      in
      {
        packages = {
          default = pkgs.stdenv.mkDerivation {
            pname = "ddf";
            version = "0.1.0";

            src = ./.;

            nativeBuildInputs = [
              zig.hook
              pkgs.pkg-config
            ];

            buildInputs = librariesToInclude;

            zigBuildFlags = [
              "-Dtarget=${zigTarget}"
              "-Drpath=${pkgs.lib.makeLibraryPath librariesToInclude}"
            ];

            postInstall = ''
              ${pkgs.patchelfUnstable}/bin/patchelf \
                --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} \
                $out/bin/${binName}
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              cmake
              gcc
              zig
              zls
              notcursesPatched
              pkg-config
              patchelfUnstable

              (writeShellScriptBin "zig-build" ''
                set -euo pipefail

                NC_DEV_LOADER=${stdenv.cc.bintools.dynamicLinker}
                NC_DEV_LIBRARY_PATH=${lib.makeLibraryPath librariesToInclude}

                zig build \
                  -Drpath="$NC_DEV_LIBRARY_PATH" \
                  -Dinterpreter="$NC_DEV_LOADER" \
                  -Dpatchelf=${patchelfUnstable}/bin/patchelf \
                  -Dbin-name=${binName} \
                  "$@"
                ${patchelfUnstable}/bin/patchelf \
                  --set-interpreter "$NC_DEV_LOADER" \
                  zig-out/bin/${binName}
              '')
            ]
            ++ treeSitterDeps;

          shellHook = ''
            export NC_DEV_LOADER=${pkgs.stdenv.cc.bintools.dynamicLinker}
            export NC_DEV_LIBRARY_PATH=${pkgs.lib.makeLibraryPath librariesToInclude}
          '';
        };
      }
    );
}
