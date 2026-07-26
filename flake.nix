{
  description = "dbx - Docker-based database backup and restore CLI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # No x86_64-darwin: nixpkgs 26.11 dropped it, and listing it would make
      # `nix flake show --all-systems` throw rather than merely skip. Intel macs
      # still have install.sh and the Homebrew formula.
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # VERSION lives in the `dbx` launcher and nowhere else — every other
      # version-carrying file is derived from it by scripts/release.sh and
      # policed by scripts/check-release-consistency.sh. Reading it here keeps
      # the flake out of that set instead of adding a 22nd file to bump.
      version =
        let
          inherit (nixpkgs) lib;
          line = lib.findFirst (l: lib.hasPrefix "VERSION=" l) null
            (lib.splitString "\n" (builtins.readFile ./dbx));
          m = if line == null then null else builtins.match ''VERSION="([^"]+)"'' line;
        in
        if m == null then throw "flake.nix: no VERSION=\"X.Y.Z\" line in ./dbx" else builtins.head m;
    in
    {
      packages = forAllSystems (pkgs:
        let
          # Wrapped onto PATH. The rule: anything dbx shells out to that is a
          # plain userland binary, so a `nix run` of dbx behaves the same on a
          # bare machine as on a fully provisioned one.
          #
          # Deliberately NOT here:
          #   docker  - a client that must match a daemon the user already runs
          #             (Docker Desktop, colima, podman shim). Pinning our own
          #             client would fight that, and the daemon can't be vendored.
          #   mc/aws  - `dbx storage` is opt-in, either client satisfies it, and
          #             both are large. Users pick one.
          #   terminal-notifier / notify-send - desktop notifications are
          #             environment-specific; dbx degrades to stdout without them.
          runtimeDeps = with pkgs; [
            jq # config is JSON; used everywhere
            zstd # backup compression
            curl # release checks, notifier webhooks
            openssh # `ssh` for tunnelled hosts
            gnupg # gpg encryption + the gpg-file vault backend
            age # age encryption backend
            openssl # wizard session token
            gum # interactive wizards hard-fail without it
            fzf # interactive backup/host selection
            pv # transfer progress on restore
            python3 # lib/wizard-server.py (browser wizard mode)
          ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            # vault_backend() prefers secret-tool over gpg-file on Linux. Since
            # we put gpg on PATH, omitting libsecret would silently demote a
            # Linux user from their keyring to gpg-file.
            libsecret
            xdg-utils # `xdg-open` for wizard browser mode
          ];
        in
        rec {
          dbx = pkgs.stdenvNoCC.mkDerivation {
            pname = "dbx";
            inherit version;

            # Only the files install.sh ships. Keeps docs/ and tests/ churn from
            # rebuilding the package.
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [ ./dbx ./lib ./man ];
            };

            strictDeps = true;
            nativeBuildInputs = [ pkgs.makeWrapper pkgs.installShellFiles ];
            # Not decorative: fixupPhase's patchShebangs resolves interpreters
            # against HOST_PATH, which strictDeps leaves empty unless something
            # is in buildInputs. Without this, `#!/usr/bin/env bash` survives
            # into $out and the result is unrunnable in any sandbox — there is
            # no /usr/bin/env in one.
            buildInputs = [ pkgs.bash ];

            dontConfigure = true;
            dontBuild = true;

            installPhase = ''
              runHook preInstall

              # dbx computes LIB_DIR as "$(dirname "$BASH_SOURCE")/lib", so the
              # launcher and lib/ must stay siblings. Keeping the real script in
              # libexec and exposing only the wrapper in bin means that holds
              # however the user reaches it.
              mkdir -p $out/libexec/dbx
              install -m755 dbx $out/libexec/dbx/dbx
              cp -R lib $out/libexec/dbx/lib

              install -Dm644 -t $out/share/man/man1 man/man1/*.1

              makeWrapper $out/libexec/dbx/dbx $out/bin/dbx \
                --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps} \
                --set-default DBX_NO_UPDATE_CHECK 1

              runHook postInstall
            '';

            # The completion scripts come from running the dbx we just built.
            # This has to happen in postFixup, not postInstall: a build sandbox
            # has no /usr/bin/env, so dbx's `#!/usr/bin/env bash` line is
            # unrunnable until patchShebangs rewrites it during fixupPhase.
            postFixup = ''
              installShellCompletion --cmd dbx \
                --bash <($out/bin/dbx completion bash) \
                --zsh <($out/bin/dbx completion zsh) \
                --fish <($out/bin/dbx completion fish)
            '';

            # `dbx version` exercises the whole source chain — if LIB_DIR
            # resolution broke, every lib/*.sh fails to source and this exits
            # non-zero. Cheap enough to run on every build.
            doInstallCheck = true;
            installCheckPhase = ''
              $out/bin/dbx version | grep -qF "${version}"
            '';

            meta = with pkgs.lib; {
              description = "Docker-based database backup and restore CLI for Postgres and MySQL";
              homepage = "https://github.com/steig/dbx";
              license = licenses.mit;
              mainProgram = "dbx";
              platforms = platforms.unix;
            };
          };

          default = dbx;
        });

      apps = forAllSystems (pkgs: rec {
        dbx = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.dbx}/bin/dbx";
          meta.description = "Run dbx without installing it: nix run github:steig/dbx -- backup prod";
        };
        default = dbx;
      });

      # Only what a build sandbox can actually do. Two suites are deliberately
      # absent, both because they cannot pass there and a check that always
      # fails is worse than no check:
      #
      #   tests/integration/ boots Postgres and MySQL in Docker.
      #   tests/unit/ writes its `docker`/`gpg`/`mc` stubs at runtime with
      #     `#!/usr/bin/env bash` heredocs, and a sandbox has no /usr/bin/env
      #     (`ls: cannot access '/usr/bin/env': Operation not permitted`).
      #     patchShebangs cannot help: the stubs are written while the tests run.
      #
      # Run both from `nix develop`, which is a normal shell on a normal
      # filesystem.
      checks = forAllSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.dbx;

        lint = pkgs.runCommand "dbx-lint" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          cd ${self}
          shellcheck -S error dbx lib/*.sh
          bash -n dbx
          for f in lib/*.sh; do bash -n "$f"; done
          touch $out
        '';

        release-consistency = pkgs.runCommand "dbx-release-consistency"
          { nativeBuildInputs = [ pkgs.gnused pkgs.gnugrep pkgs.diffutils ]; } ''
          cd ${self}
          bash scripts/check-release-consistency.sh
          touch $out
        '';

      });

      devShells = forAllSystems (pkgs: {
        # Everything CI runs (.github/workflows/ci.yml), so `nix develop` is the
        # whole contributor toolchain: no more `nix shell nixpkgs#bats --command`
        # on each invocation, and no version skew between contributors.
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            bats # test runner
            parallel # `bats -j N`
            shellcheck # lint gate
            ruff # lints lib/*.py
            actionlint # lints .github/workflows
            just # the checked-in justfile
            jq
            zstd
            age
            gnupg
            minio-client # `mc`, for dbx storage against MinIO/S3
            curl
            python3
          ];

          # >&2 so `nix develop --command foo | ...` still pipes cleanly.
          shellHook = ''
            echo "dbx ${version} dev shell — just test | just lint | bats tests/unit/" >&2
            echo "docker is NOT provided here: integration tests need your host daemon." >&2
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
