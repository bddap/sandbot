{ ... }:
let
  nixpkgs_src = builtins.fetchTarball {
    url =
      "https://github.com/NixOS/nixpkgs/archive/2e6dd569f2777e552640d3089854cb35f46193c2.tar.gz";
    sha256 = "sha256:07nlrm5cj0q4q92djm0vfjasxhvvc7happ4pwrz0ij32rdlf4g4x";
  };
  pkgs = import nixpkgs_src { };

  codex = pkgs.callPackage ./codex.nix { };

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
    # common tools need /lib64/ld-linux-x86-64.so.2 to exist, this is normally what nix-ld is
    # for. since we have the power to simply add files to the image, we do that instead.
    # I couldn't find the the derivation for the ld-linux-x86-64.so.2 from nix-ld so I
    # pull the one from glibc like a goof.
    # this one will read LD_LIBRARY_PATH instead of NIX_LD_LIBRARY_PATH?
    mkdir -p $out/lib64
    ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 $out/lib64/ld-linux-x86-64.so.2
  '';

  # write to %out/etc/nix/nix.conf
  nix_conf = pkgs.writeTextDir "etc/nix/nix.conf" ''
    # experimental-features = nix-command flakes
    # build-users-group =
  '';

  codex-wrapper = pkgs.writeShellScriptBin "codex-wrapper" ''
    set -ueo pipefail
    exec codex \
      --dangerously-bypass-approvals-and-sandbox \
      -c 'approval_policy=on-failure' \
      -c 'sandbox_mode=danger-full-access' \
      -c 'model_providers.a.env_key=OPENAI_API_KEY' \
      -c 'model_providers.a.name=openai' \
      -c 'model_providers.a.wire_api=responses' \
      -c 'model_provider=a' \
      "$@"
  '';

  cexec = pkgs.writeShellScriptBin "cexec" ''
    set -ueo pipefail
    exec codex-wrapper exec --skip-git-repo-check "$@"
  '';

  image_packages = [
    codex-wrapper
    cexec
    codex
    pkgs.ripgrep # codex prefers rg (it's built into the system prompt)
    pkgs.bash # bash is also built into the system prompt
    pkgs.nix # expect codex to use nix to manage its own dev environments
    pkgs.coreutils
    pkgs.git
    # pkgs.curl pkgs.jq pkgs.procps pkgs.psmisc pkgs.bash pkgs.coreutils-full pkgs.gnused pkgs.gawk pkgs.gnugrep pkgs.file pkgs.findutils pkgs.which
  ];

  common_shared_libs = [
    # pkgs.glibc pkgs.zlib pkgs.bzip2 pkgs.xz pkgs.ncurses pkgs.openssl pkgs.gdbm pkgs.sqlite pkgs.readline pkgs.libffi pkgs.libnsl
  ];

  image_extras = [
    ./root
    nix_conf
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    # pkgs.dockerTools.fakeNss
    empty_tmpdir
    link_loader
  ];

  write_image = pkgs.dockerTools.streamLayeredImage {
    name = "sandbot-devshell";
    tag = "sandbot-devshell";
    contents = pkgs.buildEnv {
      name = "dev-packages";
      paths = image_packages ++ common_shared_libs ++ image_extras;
    };
    config = {
      WorkingDir = "/workdir";
      Env = [
        "PATH=/usr/local/bin:/usr/bin:/bin"
        "NIX_PATH=nixpkgs=${nixpkgs_src}"
        "HOME=/root"
        "USER=root"
        "CARGO_TARGET_DIR=/root/cargo-target"
        "UV_VENV_DIR=/root/uv-venv"
      ];
    };
  };

  sandbot-load = pkgs.writeShellScriptBin "sandbot-load" ''
    set -ueo pipefail
    ${write_image} | "${pkgs.podman}/bin/podman" load --signature-policy ${allowPodmanLoad}
  '';

  sandbot-create = pkgs.writeShellScriptBin "sandbot-create" ''
    set -ueo pipefail
    if [ $# -ne 1 ]; then
      echo "Usage: $0 <bot-name>"
      exit 1
    fi
    bot_name="$1"
    container_name="sandbot-$bot_name"

    if [ -z "''${OPENAI_API_KEY:-}" ]; then
      echo "Set OPENAI_API_KEY dumbass."
      exit 1
    fi

    ${pkgs.podman}/bin/podman create -it --replace --name "$container_name" -e OPENAI_API_KEY -v "$(pwd):/workdir" "sandbot-devshell:sandbot-devshell" sleep 10000d
    ${pkgs.podman}/bin/podman start "$container_name"
    echo "Created container $container_name" >&2
    echo "You can now run commands within the sandbox with: sandbot-exec $container_name <command> [args...]" >&2
  '';

  sandbot-exec = pkgs.writeShellScriptBin "sandbot-exec" ''
    set -ueo pipefail
    if [ $# -lt 1 ]; then
      echo "Usage: $0 <container-name> [command...]"
      exit 1
    fi
    bot_name="$1"
    shift
    "${pkgs.podman}/bin/podman" exec --tty --interactive "sandbot-$bot_name" "$@"
  '';

  sandbot-destroy = pkgs.writeShellScriptBin "sandbot-destroy" ''
    set -ueo pipefail
    if [ $# -lt 1 ]; then
      echo "Usage: $0 <bot-name>"
      exit 1
    fi
    bot_name="$1"
    container_name="sandbot-$bot_name"
    shift
    "${pkgs.podman}/bin/podman" rm -f "$container_name"
  '';
in pkgs.symlinkJoin {
  name = "sandbot";
  paths = [ sandbot-load sandbot-create sandbot-exec sandbot-destroy ];
}
