# sandbot -- host-side tooling for per-project agent sandboxes.
#
# This file only builds the *launcher* scripts that run on the host. The
# sandbox image is built by `podman build` from ./Containerfile (see
# sandbot-build below); Nix is not involved in the image contents and is
# not present inside the container.
#
# Responsibilities:
#   * Pin podman (and niv-pinned nixpkgs for podman's version).
#   * Provide `sandbot-build` to build ./Containerfile into a local image.
#   * Provide the user-facing CLI: sandbot-create / -exec / -destroy /
#     -destroy-data / -persistence-root, plus the bare `sandbot` shortcut.
#
# See README.md for architecture and design goals.

{ ... }:

let
  nixpkgs_src = (import ./nix/sources.nix).nixpkgs;
  pkgs = import nixpkgs_src { config.allowUnfree = true; };

  podman = pkgs.podman;

  # Parse agent-versions.env into Nix values so `sandbot-build` can pass
  # every pin down to `podman build --build-arg`.
  versionsFile = ./agent-versions.env;
  parseEnv = text:
    let
      lines = builtins.filter
        (l: l != "" && !(pkgs.lib.hasPrefix "#" l))
        (pkgs.lib.splitString "\n" text);
      toPair = line:
        let
          m = builtins.match ''([A-Z_][A-Z0-9_]*)="?([^"]*)"?'' line;
        in
          if m == null then null else { name = builtins.elemAt m 0; value = builtins.elemAt m 1; };
      pairs = builtins.filter (p: p != null) (map toPair lines);
    in
      builtins.listToAttrs pairs;
  versions = parseEnv (builtins.readFile versionsFile);

  # Escape a value for safe inclusion in a double-quoted shell string.
  shEscape = s: builtins.replaceStrings [ "\\" "\"" "$" "`" ] [ "\\\\" "\\\"" "\\$" "\\`" ] s;

  buildArgsShell = pkgs.lib.concatStringsSep " " (map
    (name: "--build-arg ${name}=\"${shEscape versions.${name}}\"")
    (builtins.attrNames versions));

  imageTag = "sandbot-devshell:latest";

  # ---- sandbot-build -------------------------------------------------------
  # Build the sandbox image from ./Containerfile, passing every pin in
  # agent-versions.env as a --build-arg. Run from the directory containing
  # Containerfile (the script resolves it via $SANDBOT_SRC or the cwd).
  sandbot-build = pkgs.writeShellScriptBin "sandbot-build" ''
    set -ueo pipefail
    src="''${SANDBOT_SRC:-${toString ./.}}"
    if [ ! -f "$src/Containerfile" ]; then
      echo "sandbot-build: Containerfile not found at $src/Containerfile" >&2
      echo "Set SANDBOT_SRC to the directory containing Containerfile." >&2
      exit 1
    fi
    echo "Building ${imageTag} from $src/Containerfile ..." >&2
    exec "${podman}/bin/podman" build \
      --pull=newer \
      -f "$src/Containerfile" \
      -t "${imageTag}" \
      ${buildArgsShell} \
      "$src"
  '';

  # ---- sandbot-persistence-root -------------------------------------------
  # Where per-bot agent state (opencode/codex/claude caches) lives on the host.
  # XDG_STATE_HOME takes precedence; falls back to ~/.local/state/sandbot/<bot>.
  sandbot-persistence-root = pkgs.writeShellScriptBin "sandbot-persistence-root" ''
    set -ueo pipefail
    if [ $# -lt 1 ]; then
      echo "Usage: $0 <bot-name>" >&2
      exit 1
    fi
    bot_name="$1"
    base="''${XDG_STATE_HOME:-$HOME/.local/state}"
    printf '%s\n' "$base/sandbot/$bot_name"
  '';

  # ---- sandbot-create ------------------------------------------------------
  # Create-or-replace a container named sandbot-<botname> backed by the
  # devshell image. Bind-mounts the project at /workdir and per-bot agent
  # state dirs under /root. Does NOT mount anything else from the host.
  #
  # Isolation posture:
  #   --userns=auto           -> container root maps to an unprivileged
  #                              dynamic host uid range
  #   --cap-add=SYS_PTRACE    -> agents can strace/gdb (on top of the default
  #                              podman cap set which already covers apt/ping)
  #   --security-opt=no-new-privileges
  #                           -> suid binaries inside can't escalate
  #   network on              -> apt/pip/npm/cargo/curl "just work"
  sandbot-create = pkgs.writeShellScriptBin "sandbot-create" ''
    set -ueo pipefail
    if [ $# -ge 1 ]; then
      bot_name="$1"
    else
      bot_name="$(pwd | sed 's/[^a-zA-Z0-9_.-]/_/g')"
    fi
    container_name="sandbot-$bot_name"
    sandbox_root="$(${sandbot-persistence-root}/bin/sandbot-persistence-root "$bot_name")"

    # Agent state dirs. Keep the list short and explicit -- anything an
    # agent writes outside these is lost on sandbot-destroy (by design).
    for rel in \
        .config/opencode  .local/share/opencode  .local/state/opencode  .cache/opencode \
        .config/codex     .local/share/codex \
        .claude           .config/claude \
        .config/gemini    .gemini ; do
      mkdir -p "$sandbox_root/$rel"
    done

    if [ -z "''${OPENAI_API_KEY:-}" ]; then
      echo "warning: OPENAI_API_KEY not set in the calling shell." >&2
    fi
    if [ -z "''${ANTHROPIC_API_KEY:-}" ]; then
      echo "warning: ANTHROPIC_API_KEY not set in the calling shell." >&2
    fi

    # SANDBOT_GPU=1 grants direct access to the host's NVIDIA GPU. Note: GPU
    # memory is not namespaced -- processes in the container can potentially
    # read GPU memory of other host processes sharing the same device.
    gpu_flags=()
    if [ "''${SANDBOT_GPU:-0}" = "1" ]; then
      gpu_flags+=(--device "nvidia.com/gpu=all")
      gpu_flags+=(-e "NVIDIA_VISIBLE_DEVICES=all")
      gpu_flags+=(-e "NVIDIA_DRIVER_CAPABILITIES=compute,utility")
      echo "GPU access enabled." >&2
    fi

    if ! "${podman}/bin/podman" image exists "${imageTag}"; then
      echo "error: image ${imageTag} not found. Run 'sandbot-build' first." >&2
      exit 1
    fi

    "${podman}/bin/podman" create -it --replace --name "$container_name" \
        --userns=auto \
        --cap-add=SYS_PTRACE \
        --security-opt=no-new-privileges \
        "''${gpu_flags[@]}" \
        -e OPENAI_API_KEY -e ANTHROPIC_API_KEY \
        -v "$(pwd):/workdir" \
        -v "$sandbox_root/.config/opencode:/root/.config/opencode" \
        -v "$sandbox_root/.local/share/opencode:/root/.local/share/opencode" \
        -v "$sandbox_root/.local/state/opencode:/root/.local/state/opencode" \
        -v "$sandbox_root/.cache/opencode:/root/.cache/opencode" \
        -v "$sandbox_root/.config/codex:/root/.config/codex" \
        -v "$sandbox_root/.local/share/codex:/root/.local/share/codex" \
        -v "$sandbox_root/.claude:/root/.claude" \
        -v "$sandbox_root/.config/claude:/root/.config/claude" \
        -v "$sandbox_root/.config/gemini:/root/.config/gemini" \
        -v "$sandbox_root/.gemini:/root/.gemini" \
        "${imageTag}" \
        >/dev/null
    "${podman}/bin/podman" start "$container_name" >/dev/null
    echo "Created $container_name" >&2
    echo "  image:        ${imageTag}" >&2
    echo "  project:      $(pwd) -> /workdir" >&2
    echo "  agent state:  $sandbox_root" >&2
    echo "Shell in with:  sandbot"
    echo "Exec a command: sandbot <cmd> [args...]"
  '';

  # ---- sandbot-destroy / sandbot-destroy-data -----------------------------
  sandbot-destroy = pkgs.writeShellScriptBin "sandbot-destroy" ''
    set -ueo pipefail
    if [ $# -ge 1 ]; then
      bot_name="$1"
    else
      bot_name="$(pwd | sed 's/[^a-zA-Z0-9_.-]/_/g')"
    fi
    "${podman}/bin/podman" rm -f "sandbot-$bot_name" >/dev/null
    echo "Destroyed sandbot-$bot_name" >&2
  '';

  sandbot-destroy-data = pkgs.writeShellScriptBin "sandbot-destroy-data" ''
    set -ueo pipefail
    if [ $# -ge 1 ]; then
      bot_name="$1"
    else
      bot_name="$(pwd | sed 's/[^a-zA-Z0-9_.-]/_/g')"
    fi
    sandbox_root="$(${sandbot-persistence-root}/bin/sandbot-persistence-root "$bot_name")"
    if [ ! -d "$sandbox_root" ]; then
      echo "No persisted data for $bot_name at $sandbox_root" >&2
      exit 0
    fi
    rm -rf -- "$sandbox_root"
    echo "Removed $sandbox_root" >&2
  '';

  # ---- sandbot-exec: run a command in a specific bot ----------------------
  sandbot-exec = pkgs.writeShellScriptBin "sandbot-exec" ''
    set -ueo pipefail
    if [ $# -lt 1 ]; then
      echo "Usage: $0 <bot-name> [command...]" >&2
      exit 1
    fi
    bot_name="$1"
    shift
    if [ $# -eq 0 ]; then
      set -- bash
    fi
    exec "${podman}/bin/podman" exec --tty --interactive "sandbot-$bot_name" "$@"
  '';

  # ---- sandbot: one-command UX for the current project --------------------
  # Derives bot name from cwd. Creates+starts the container if missing, then
  # execs the requested command (or drops into a bash shell with no args).
  sandbot = pkgs.writeShellScriptBin "sandbot" ''
    set -ueo pipefail
    bot_name="$(pwd | sed 's/[^a-zA-Z0-9_.-]/_/g')"
    container_name="sandbot-$bot_name"

    # Create-if-missing. Start-if-stopped. Cheap if already running.
    if ! "${podman}/bin/podman" container exists "$container_name" 2>/dev/null; then
      "${sandbot-create}/bin/sandbot-create" "$bot_name" >&2
    else
      state="$("${podman}/bin/podman" inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo unknown)"
      if [ "$state" != "running" ]; then
        "${podman}/bin/podman" start "$container_name" >/dev/null
      fi
    fi

    if [ $# -eq 0 ]; then
      set -- bash
    fi
    exec "${podman}/bin/podman" exec --tty --interactive "$container_name" "$@"
  '';

in pkgs.symlinkJoin {
  name = "sandbot";
  paths = [
    sandbot-build
    sandbot-create
    sandbot-destroy
    sandbot-destroy-data
    sandbot-persistence-root
    sandbot-exec
    sandbot
  ];
}
