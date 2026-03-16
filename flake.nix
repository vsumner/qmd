{
  description = "QMD - Quick Markdown Search";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # SQLite with loadable extension support for sqlite-vec
        sqliteWithExtensions = pkgs.sqlite.overrideAttrs (old: {
          configureFlags = (old.configureFlags or []) ++ [
            "--enable-load-extension"
          ];
        });

        # Use npm for initial fetch since bun has issues with ignore-scripts
        nodeModules = pkgs.stdenv.mkDerivation {
          pname = "qmd-node-modules";
          version = "2.0.1";
          src = ./.;

          nativeBuildInputs = [
            pkgs.nodejs
            pkgs.python3
          ];

          dontConfigure = true;
          dontFixup = true;
          noChroot = true;  # Allow network access for npm

          buildPhase = ''
            export HOME=$(mktemp -d)
            # Use npm with ignore-scripts to download without building
            npm ci --ignore-scripts --cache $(mktemp -d)
          '';

          installPhase = ''
            mkdir -p $out
            cp -r node_modules $out/
            cp package.json $out/
            cp bun.lock $out/ 2>/dev/null || true
            cp package-lock.json $out/ 2>/dev/null || true
          '';

          outputHash = "sha256-G9IdZhvhZcIbmPIXbyrlaUMKKOPMTS9gmylZG/u4bzw=";
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
        };

        qmd = pkgs.stdenv.mkDerivation {
          pname = "qmd";
          version = "2.0.1";

          src = ./.;

          nativeBuildInputs = [
            pkgs.bun
            pkgs.makeWrapper
            pkgs.nodejs
            pkgs.python3
            pkgs.gcc
            pkgs.nodePackages.node-gyp
          ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
            pkgs.darwin.cctools
          ];

          buildInputs = [ pkgs.sqlite ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            export npm_config_nodedir=${pkgs.nodejs}
            export npm_config_python=${pkgs.python3}/bin/python3

            # Copy prefetched node_modules
            cp -r ${nodeModules}/node_modules .
            chmod -R u+w node_modules

            # Build native modules (better-sqlite3)
            cd node_modules/better-sqlite3
            ${pkgs.nodePackages.node-gyp}/bin/node-gyp rebuild
            cd ../..

            # Try to handle node-llama-cpp - if it exists, rebuild it too
            if [ -d node_modules/node-llama-cpp ]; then
              cd node_modules/node-llama-cpp
              # Set up environment for node-llama-cpp
              export NODE_LLAMA_CPP_SKIP_DOWNLOAD=true
              export CUDA_DISABLED=1
              ${pkgs.nodePackages.node-gyp}/bin/node-gyp rebuild 2>/dev/null || true
              cd ../..
            fi
          '';

          installPhase = ''
            mkdir -p $out/lib/qmd
            mkdir -p $out/bin

            cp -r node_modules $out/lib/qmd/
            cp -r src $out/lib/qmd/
            cp package.json $out/lib/qmd/

            # Create wrapper script with correct path and env vars
            makeWrapper ${pkgs.bun}/bin/bun $out/bin/qmd \
              --add-flags "$out/lib/qmd/src/cli/qmd.ts" \
              --set DYLD_LIBRARY_PATH "${pkgs.sqlite.out}/lib" \
              --set LD_LIBRARY_PATH "${pkgs.sqlite.out}/lib" \
              --set NODE_LLAMA_CPP_SKIP_DOWNLOAD "1" \
              --set CUDA_DISABLED "1"
          '';

          meta = with pkgs.lib; {
            description = "On-device search engine for markdown notes, meeting transcripts, and knowledge bases";
            homepage = "https://github.com/tobi/qmd";
            license = licenses.mit;
            platforms = platforms.unix;
          };
        };
      in
      {
        packages = {
          default = qmd;
          qmd = qmd;
          nodeModules = nodeModules;
        };

        apps.default = {
          type = "app";
          program = "${qmd}/bin/qmd";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.bun
            sqliteWithExtensions
          ];

          shellHook = ''
            export BREW_PREFIX="''${BREW_PREFIX:-${sqliteWithExtensions.out}}"
            echo "QMD development shell"
            echo "Run: bun src/cli/qmd.ts <command>"
          '';
        };
      }
    );
}
