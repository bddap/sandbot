{ ... }:
let
  nixpkgs_src = (import ./nix/sources.nix).nixpkgs;
  pkgs = import nixpkgs_src { config.allowUnfree = true; };

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
    # common tools need /lib64/ld-linux-x86-64.so.2 to exist. We'll just link glibc's loader here.
    mkdir -p $out/lib64
    ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 $out/lib64/ld-linux-x86-64.so.2
  '';

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
    pkgs.gemini-cli
    codex-wrapper
    cexec
    codex
    pkgs.claude-code
    pkgs.opencode
    pkgs.ripgrep
    pkgs.bash
    pkgs.nix
    pkgs.coreutils-full
    pkgs.findutils
    pkgs.gnugrep
    pkgs.git
    pkgs.jq
    pkgs.gawk
  ];

  common_shared_libs = [ ];

  image_extras = [
    ./root
    nix_conf
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
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
        "IS_SANDBOX=1" # prevent overzealous claude-code from disabling running as root https://github.com/anthropics/claude-code/issues/927
      ];
    };
  };

  sandbot-load = pkgs.writeShellScriptBin "sandbot-load" ''
    set -ueo pipefail
    ${write_image} | "${pkgs.podman}/bin/podman" load --signature-policy ${allowPodmanLoad}
  '';

  sandbot-create = pkgs.writeShellScriptBin "sandbot-create" ''
    set -ueo pipefail

    if [ $# -ge 1 ]; then
      bot_name="$1"
    else
      # generate from the full CWD
      safe_string="$(pwd | sed 's/[^a-zA-Z0-9_.-]/_/g')"
      bot_name="$safe_string"
    fi
    container_name="sandbot-$bot_name"

    if [ -z "''${OPENAI_API_KEY:-}" ]; then
      echo "Careful, you didn't set OPENAI_API_KEY."
    fi
    if [ -z "''${ANTHROPIC_API_KEY:-}" ]; then
      echo "Careful, you didn't set ANTHROPIC_API_KEY."
    fi

    ${pkgs.podman}/bin/podman create -it --replace --name "$container_name" \
        -e OPENAI_API_KEY -e ANTHROPIC_API_KEY \
        -v "$(pwd):/workdir" "sandbot-devshell:sandbot-devshell" \
        sleep 10000d
    ${pkgs.podman}/bin/podman start "$container_name"
    echo "Created container $container_name" >&2
    echo "You can now run commands within the sandbox with: sandbot-exec $bot_name <command> [args...]" >&2
  '';

  sandbot-destroy = pkgs.writeShellScriptBin "sandbot-destroy" ''
    set -ueo pipefail

    if [ $# -ge 1 ]; then
      bot_name="$1"
      shift
    else
      # generate from the full CWD
      safe_string="$(pwd | sed 's/[^a-zA-Z0-9_.-]/_/g')"
      bot_name="$safe_string"
    fi

    container_name="sandbot-$bot_name"
    "${pkgs.podman}/bin/podman" rm -f "$container_name"
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

  sandbot = pkgs.writeShellScriptBin "sandbot" ''
    set -ueo pipefail
    # Derive bot name from cwd
    safe_string="$(pwd | sed 's/[^a-zA-Z0-9_.-]/_/g')"
    bot_name="$safe_string"
    container_name="sandbot-$bot_name"

    if [ $# -lt 1 ]; then
      echo "Usage: $0 <command> [args...]"
      exit 1
    fi

    exec "${pkgs.podman}/bin/podman" exec --tty --interactive "$container_name" "$@"
  '';
in pkgs.symlinkJoin {
  name = "sandbot";
  paths = [ sandbot-load sandbot-create sandbot-exec sandbot-destroy sandbot ];
}
