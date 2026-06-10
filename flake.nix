{
  description = "flake for df";

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

        notcursesPatched = pkgs.notcurses.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            (pkgs.fetchpatch {
              url = "https://github.com/dankamongmen/notcurses/pull/2926.patch";
              hash = "sha256-1EBbQZghAyvXks5KClStgZ1VXd4MGKm4NwkSXQOluXw=";
            })
          ];
        });

        librariesToInclude = [
          notcursesPatched
          pkgs.ncurses
          pkgs.libunistring
          pkgs.libdeflate
          pkgs.glibc
          pkgs.glibc
          pkgs.stdenv.cc.cc.lib
        ];

        binName = "df";
      in
      {
        packages = {
          default = pkgs.stdenv.mkDerivation {
            pname = "df";
            version = "0.1.0";

            src = ./.;

            nativeBuildInputs = [
              zig.hook
              pkgs.zig-config
            ];

            buildInputs = [
              notcursesPatched
            ];

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
          packages = with pkgs; [
            cmake
            gcc
            zig
            zls
            notcursesPatched
            pkg-config

            (writeShellScriptBin "zig-build" ''
              set -euo pipefail

              NC_DEV_LOADER=${stdenv.cc.bintools.dynamicLinker}
              NC_DEV_LIBRARY_PATH=${lib.makeLibraryPath librariesToInclude}

              zig build \
                -Drpath="$NC_DEV_LIBRARY_PATH" "$@" \
                -Dbin-name=${binName}
              ${patchelfUnstable}/bin/patchelf \
                --set-interpreter "$NC_DEV_LOADER" \
                zig-out/bin/${binName}
            '')
          ];

          shellHook = ''
            export NC_DEV_LOADER=${pkgs.stdenv.cc.bintools.dynamicLinker}
            export NC_DEV_LIBRARY_PATH=${pkgs.lib.makeLibraryPath librariesToInclude}
          '';
        };
      }
    );
}
