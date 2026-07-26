# Homebrew formula for dbx. Lives in the dbx repo itself rather than a separate
# `homebrew-dbx` tap so that the drift guard, CI and the release script can all
# see it — a second repository would be a second hand-maintained copy of the
# version, which is the failure mode #122 already cost us once.
#
#   brew tap steig/dbx https://github.com/steig/dbx
#   brew install dbx
#
# The two-argument `brew tap` is what makes an un-prefixed repo tappable; see
# docs/homebrew.md. `url`/`sha256` are rewritten by scripts/update-formula.sh
# AFTER a tag is pushed — never by hand, and never in the release commit
# itself, because the digest is of a tarball that contains this file.
class Dbx < Formula
  desc "Database backup and restore CLI for PostgreSQL, MySQL, and MariaDB"
  homepage "https://github.com/steig/dbx"
  url "https://github.com/steig/dbx/archive/refs/tags/v0.39.1.tar.gz"
  sha256 "fee64641a448896635e2f85ae9792f5026ab7b57d0bdad298871d0788cc5d376"
  license "MIT"
  head "https://github.com/steig/dbx.git", branch: "main"

  livecheck do
    url :stable
    strategy :github_latest
  end

  # Only the two dependencies dbx cannot run a single command without. Docker is
  # deliberately absent: it is a cask (Docker Desktop), and Colima, OrbStack,
  # Podman and Rancher Desktop all satisfy dbx equally well — pulling in a
  # 700 MB GUI to install a bash script would be wrong for most of this
  # audience. The optional tools (age, gnupg, gum, mc, aws, fzf, pv) each gate a
  # single subcommand and are named in the caveats instead.
  depends_on "jq"
  depends_on "zstd"

  def install
    # dbx finds its libraries relative to itself — `LIB_DIR="$SCRIPT_DIR/lib"`,
    # where SCRIPT_DIR is `dirname "${BASH_SOURCE[0]}"` — so the launcher and
    # lib/ must stay siblings. Installing both under libexec and exec-ing from
    # bin keeps that true without patching a single shipped byte, which matters
    # here: the tarball digest above is the only integrity check, so the less
    # this formula rewrites, the more that digest actually covers.
    #
    # A symlink would NOT work: BASH_SOURCE[0] is the path used to invoke the
    # script, and `cd $(dirname link) && pwd` yields the symlink's directory, so
    # LIB_DIR would resolve to bin/lib. write_exec_script emits a two-line
    # wrapper that execs the real path, so BASH_SOURCE[0] is the libexec one.
    libexec.install "dbx", "lib"
    bin.write_exec_script libexec/"dbx"

    man1.install Dir["man/man1/*.1"]

    # Runs `dbx completion <shell>` against the just-installed launcher, so the
    # completions can never describe a different version than the binary. Needs
    # libexec/lib in place, hence the ordering.
    generate_completions_from_executable(libexec/"dbx", "completion",
                                         shells: [:bash, :zsh, :fish])
  end

  def caveats
    <<~EOS
      dbx runs pg_dump/mysqldump inside containers, so it needs a Docker daemon
      on your PATH. Docker Desktop, OrbStack, Colima and Rancher Desktop all
      work — that is why this formula does not pull one in for you.

      Optional, install what you use:
        age or gnupg      backup encryption, and the headless vault fallback
        gum               the interactive wizards (dbx host add, dbx storage add)
        minio-mc or awscli  S3/MinIO offload (dbx storage)
        fzf               interactive backup picker for restore and verify
        pv                progress bar during MySQL restore

      Upgrade with `brew upgrade dbx`. Do not use `dbx update` on a Homebrew
      install — it re-runs the curl installer and leaves a second, unmanaged
      copy in ~/.local/bin.
    EOS
  end

  test do
    # No network and no writes outside the sandbox: the update check would
    # otherwise call GitHub, and `config init` would otherwise write ~/.config.
    ENV["DBX_NO_UPDATE_CHECK"] = "1"
    ENV["DBX_CONFIG_DIR"] = testpath/"config"

    # The load-bearing assertion. It proves three things at once: the exec
    # wrapper resolves libexec/lib (dbx sources all 14 libraries before it can
    # print anything), the tarball we unpacked really is the tag `url` claims,
    # and the formula's version matches the launcher's. A `url` bumped without
    # its `sha256` is caught by brew before this runs; a `sha256` that is
    # genuinely some *other* tag's is caught right here.
    assert_match(/^dbx #{Regexp.escape(version.to_s)}$/, shell_output("#{bin}/dbx version"))
    assert_match "Database backup and restore utility", shell_output("#{bin}/dbx help")

    # One command that does real work. Needs jq, needs no Docker and no network.
    system bin/"dbx", "config", "init"
    assert_path_exists testpath/"config/config.json"
  end
end
