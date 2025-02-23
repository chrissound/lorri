{ pkgs ? import ./nix/nixpkgs.nix { enableMozillaOverlay = true; }
, isDevelopmentShell ? true }:

# Must have the stable rust overlay (enableMozillaOverlay)
assert isDevelopmentShell -> pkgs ? latest;

let
  rustChannels =
    pkgs.lib.mapAttrs
      (_: v: pkgs.rustChannelOf v)
      (import ./nix/rust-channels.nix {
        stableVersion = "1.35.0";
      });
in
pkgs.mkShell rec {
  name = "lorri";
  buildInputs = [
    # This rust comes from the Mozilla rust overlay so we can
    # get Clippy. Not suitable for production builds. See
    # ./nix/nixpkgs.nix for more details.
    rustChannels.stable.rust
    pkgs.bashInteractive
    pkgs.git
    pkgs.direnv
    pkgs.shellcheck
    pkgs.carnix
    pkgs.nix-prefetch-git

    # To ensure we always have a compatible nix in our shells.
    # Travis doesn’t know `nix-env` otherwise.
    pkgs.nix
  ] ++
  pkgs.stdenv.lib.optionals pkgs.stdenv.isDarwin [
    pkgs.darwin.Security
    pkgs.darwin.apple_sdk.frameworks.CoreServices
    pkgs.darwin.apple_sdk.frameworks.CoreFoundation
  ] ++
  pkgs.stdenv.lib.optionals isDevelopmentShell [
    (pkgs.callPackage ./nix/racer.nix { rustNightly = rustChannels.nightly; })
  ];

  # Keep project-specific shell commands local
  HISTFILE = "${toString ./.}/.bash_history";

  # Lorri-specific

  # The root directory of this project
  LORRI_ROOT = toString ./.;
  # Needed by the lorri build.rs to determine its own version
  # for the development repository (non-release), we set it to 1
  BUILD_REV_COUNT = 1;
  # Needed by the lorri build.rs to access some tools used during
  # the build of lorri's environment derivations.
  RUN_TIME_CLOSURE = pkgs.callPackage ./nix/runtime.nix {};

  # Rust-specific

  # Enable printing backtraces for rust binaries
  RUST_BACKTRACE = 1;
  # Needed for racer “jump to definition” editor support
  # In Emacs with `racer-mode`, you need to set
  # `racer-rust-src-path` to `nil` for it to pick
  # up the environment variable with `direnv`.
  RUST_SRC_PATH = "${rustChannels.stable.rust-src}/lib/rustlib/src/rust/src/";
  # Set up a local directory to install binaries in
  CARGO_INSTALL_ROOT = "${LORRI_ROOT}/.cargo";


  # Executed when entering `nix-shell`
  shellHook = ''
    # we can only output to stderr in the shellHook,
    # otherwise direnv `use nix` does not work.
    # see https://github.com/direnv/direnv/issues/427
    exec 3>&1 # store stdout (1) in fd 3
    exec 1>&2 # make stdout (1) an alias for stderr (2)

    # this is needed so `lorri shell` runs the proper shell from
    # inside this project's nix-shell. If you run `lorri` within a
    # nix-shell, you don't need this.
    export SHELL="${pkgs.bashInteractive}/bin/bash";

    alias newlorri="(cd $LORRI_ROOT; cargo run -- shell)"
    alias ci="ci_check"

    # this is mirrored from .envrc to make available from nix-shell
    # pick up cargo plugins
    export PATH="$LORRI_ROOT/.cargo/bin:$PATH"
    # watch the output to add lorri once it's built
    export PATH="$LORRI_ROOT/target/debug:$PATH"

    function ci_check() (
      cd "$LORRI_ROOT";
      source ./.travis_fold.sh

      set -x

      lorri_travis_fold carnix-update ./nix/update-carnix.sh
      carnixupdate=$?

      lorri_travis_fold script-tests ./script-tests/run-all.sh
      scripttests=$?

      lorri_travis_fold cargo-test cargo test
      cargotestexit=$?

      lorri_travis_fold cargo-fmt \
        cargo fmt -- --check
      cargofmtexit=$?

      RUSTFLAGS='-D warnings' \
        lorri_travis_fold cargo-clippy cargo clippy
      cargoclippyexit=$?

      set +x
      echo "carnix update: $carnixupdates"
      echo "script tests: $scripttests"
      echo "cargo test: $cargotestexit"
      echo "cargo fmt: $cargofmtexit"
      echo "cargo clippy: $cargoclippyexit"

      sum=$((carnixupdate + scripttest + cargotestexit + cargofmtexit + cargoclippyexit))
      if [ "$sum" -gt 0 ]; then
        return 1
      fi
    )

    ${pkgs.lib.optionalString isDevelopmentShell ''
      echo "lorri" | ${pkgs.figlet}/bin/figlet | ${pkgs.lolcat}/bin/lolcat
      (
        format="  %-12s %s\n"
        printf "$format" alias executes
        printf "$format" ----- --------
        IFS=$'\n'
        for line in $(alias); do
          [[ $line =~ ^alias\ ([^=]+)=(\'.*\') ]]
          printf "$format" "''${BASH_REMATCH[1]}" "''${BASH_REMATCH[2]}"
        done
      )
    ''}

    # restore stdout and close 3
    exec 1>&3-
  '' + (if !pkgs.stdenv.isDarwin then "" else ''
    # Cargo wasn't able to find CF during a `cargo test` run on Darwin.
    export NIX_LDFLAGS="-F${pkgs.darwin.apple_sdk.frameworks.CoreFoundation}/Library/Frameworks -framework CoreFoundation $NIX_LDFLAGS"
  '');

  preferLocalBuild = true;
  allowSubstitutes = false;
}
