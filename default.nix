{ ... }:
let
  nixpkgs_src = builtins.fetchTarball {
    url =
      "https://github.com/NixOS/nixpkgs/archive/2e6dd569f2777e552640d3089854cb35f46193c2.tar.gz";
    sha256 = "sha256:07nlrm5cj0q4q92djm0vfjasxhvvc7happ4pwrz0ij32rdlf4g4x";
  };
  pkgs = import nixpkgs_src { };

  codex = import ./codex.nix { inherit pkgs; };

  allowPodmanLoad = pkgs.writeText "podman-policy.json" (builtins.toJSON {
    default = [{ type = "reject"; }];
    transports = {
      docker-archive = { "" = [{ type = "insecureAcceptAnything"; }]; };
    };
  });

  empty_tmpdir = (pkgs.stdenv.mkDerivation {
    name = "tmp";
    buildCommand = ''
      mkdir -p $out/tmp
    '';
  });
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
    pkgs.glibc
    pkgs.zlib
    pkgs.bzip2
    pkgs.xz
    pkgs.ncurses
    pkgs.openssl
    pkgs.gdbm
    pkgs.sqlite
    pkgs.readline
    pkgs.libffi
    pkgs.libnsl
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

  sandbot-codex = pkgs.writeShellScriptBin "sandbot-codex" ''
    set -ueo pipefail
    exec ${sandbot}/bin/sandbot env RUST_LOG=debug codex \
      --dangerously-bypass-approvals-and-sandbox \
      -c 'approval_policy=on-failure' \
      -c 'sandbox_mode=danger-full-access' \
      -c 'model_providers.a.env_key=OPENAI_API_KEY' \
      -c 'model_providers.a.name=openai' \
      -c 'model_providers.a.wire_api=responses' \
      -c 'model_provider=a' \
      "$@"
  '';

  sandbot = pkgs.writeShellScriptBin "sandbot" ''
    set -ueo pipefail
    exec "${pkgs.podman}/bin/podman" run --rm -it -e OPENAI_API_KEY -v "$(pwd):/workdir" "sandbot-devshell:sandbot-devshell" "$@"
  '';
in pkgs.symlinkJoin {
  name = "sandbot";
  paths = [ sandbot-load sandbot-codex sandbot ];
}
