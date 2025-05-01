{ ... }:
let
  nixpkgs_src = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/5cfaab2c5c1492cbec3e5e85a4dca8601858a06a.tar.gz";
    sha256 = "sha256:13fs75rars50m49ngxbnk1ms4k2gv7ll9zwf6y64wlvpzw44vwnr";
  };
  pkgs = import nixpkgs_src { };

  codex = make_codex pkgs;
  make_codex =
    {
      fetchFromGitHub,
      stdenv,
      pnpm,
      nodejs,
      makeWrapper,
      ...
    }:

    stdenv.mkDerivation rec {
      pname = "codex-cli";
      version = (builtins.fromJSON (builtins.readFile "${src}/codex-cli/package.json")).version;
      src = fetchFromGitHub {
        owner = "openai";
        repo = "codex";
        rev = "ebd2ae4abdefad104437147d4e27e4d90200492e";
        sha256 = "sha256-QWaeTVuM400GfRe60klxjaK4diuoKY+SVIB+KNuKRsE=";
      };
      sourceRoot = src.name;
      nativeBuildInputs = [
        pnpm
        pnpm.configHook
        makeWrapper
      ];
      buildInputs = [
        nodejs
      ];

      pnpmDeps = pnpm.fetchDeps {
        inherit pname version src;
        hash = "sha256-pPwHjtqqaG+Zqmq6x5o+WCT1H9XuXAqFNKMzevp7wTc=";
      };

      buildPhase = ''
        cd ${pname}
        pnpm install --frozen-lockfile
        pnpm run build
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin
        mkdir -p $out/lib

        install -Dm644 dist/cli.js $out/lib/cli.js
        makeWrapper ${nodejs}/bin/node $out/bin/codex \
          --add-flags "$out/lib/cli.js"

        runHook postInstall
      '';
    };

  codex_o3 = pkgs.writeShellScriptBin "codex-o3" ''
    exec ${codex}/bin/codex --full-auto --model o3 "$@"
  '';

  allowPodmanLoad = pkgs.writeText "podman-policy.json" (
    builtins.toJSON {
      default = [ { type = "reject"; } ];
      transports = {
        docker-archive = {
          "" = [
            {
              type = "insecureAcceptAnything";
            }
          ];
        };
      };
    }
  );

  empty_tmpdir = (
    pkgs.stdenv.mkDerivation {
      name = "tmp";
      buildCommand = ''
        mkdir -p $out/tmp
      '';
    }
  );
  link_loader = pkgs.runCommand "link-loader" { } ''
    # common tools need /lib64/ld-linux-x86-64.so.2 to exist, this is what nix-ld is for
    # I couldn't find the the derivation for the ld-linux-x86-64.so.2 from nix-ld so I
    # pull the one from glibc like a goof.
    # this one will read LD_LIBRARY_PATH instead of NIX_LD_LIBRARY_PATH I think
    mkdir -p $out/lib64
    ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 $out/lib64/ld-linux-x86-64.so.2
  '';

  # Add shared libraries for uv’s custom Python below:
  image_packages = [
    codex
    codex_o3
    # pkgs.cargo
    # pkgs.clippy
    # pkgs.rustfmt
    pkgs.git
    pkgs.curl
    # pkgs.dnsutils
    # pkgs.fzf
    # pkgs.gh
    # pkgs.gnupg
    pkgs.jq
    # pkgs.less
    # pkgs.man-db
    pkgs.procps
    pkgs.psmisc
    # pkgs.unzip
    pkgs.ripgrep
    pkgs.bash
    pkgs.coreutils-full
    # pkgs.clang
    pkgs.gnused
    pkgs.gawk
    pkgs.python3
    pkgs.gnugrep
    pkgs.file
    pkgs.findutils
    pkgs.just
    # pkgs.cmake
    pkgs.nix
    pkgs.which
    # pkgs.gnutar
    pkgs.uv
    # pkgs.patchelf
  ];

  common_shared_libs = [
    # pkgs.glibc
    # pkgs.zlib
    # pkgs.bzip2
    # pkgs.xz
    # pkgs.ncurses
    # pkgs.openssl
    # pkgs.gdbm
    # pkgs.sqlite
    # pkgs.readline
    # pkgs.libffi
    # pkgs.libnsl
  ];

  image_extras = [
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    pkgs.dockerTools.fakeNss
    empty_tmpdir
    link_loader
    # pkgs.nix-ld
  ];
  all_image_packages = image_packages ++ common_shared_libs ++ image_extras;

  env = pkgs.buildEnv {
    name = "dev-packages";
    paths = all_image_packages;
  };

  write_container = pkgs.dockerTools.streamLayeredImage {
    name = "sandbot-devshell";
    tag = "sandbot-devshell";
    contents = env;

    includeStorePaths = true;

    config = {
      WorkingDir = "/workdir";
      Env = [
        "PATH=/usr/local/bin:/usr/bin:/bin"
        "NIX_PATH=nixpkgs=${nixpkgs_src}"
        "NIX_CONFIG=build-users-group = root"
        # "NIX_LD_LIBARY_PATH=${pkgs.lib.makeLibraryPath [ env ]}"
        "LD_LIBARY_PATH=${pkgs.lib.makeLibraryPath [ env ]}"
        "HOME=/root"
        "CARGO_TARGET_DIR=/root/cargo-target"
        "UV_VENV_DIR=/root/uv-venv"
      ];
    };
  };

  sandbot-load = pkgs.writeShellScriptBin "sandbot-load" ''
    set -ueo pipefail
    ${write_container} | "${pkgs.podman}/bin/podman" load --signature-policy ${allowPodmanLoad}
  '';

  sandbot-run = pkgs.writeShellScriptBin "sandbot-run" ''
    set -ueo pipefail
    "${pkgs.podman}/bin/podman" run --rm -it -e OPENAI_API_KEY -v "$(pwd):/workdir" "sandbot-devshell:sandbot-devshell" codex --full-auto --model o3
  '';

  sandbot-shell = pkgs.writeShellScriptBin "sandbot-shell" ''
    set -ueo pipefail
    "${pkgs.podman}/bin/podman" run --rm -it -e OPENAI_API_KEY -v "$(pwd):/workdir" "sandbot-devshell:sandbot-devshell" ${pkgs.bash}/bin/bash
  '';
in
pkgs.symlinkJoin {
  name = "sandbot";
  paths = [
    sandbot-load
    sandbot-run
    sandbot-shell
  ];
}
