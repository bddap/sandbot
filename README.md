# sandbot

Per-project agent sandboxes. Runs your code-writing agent (codex, opencode,
claude-code, gemini-cli, ...) inside a rootless Debian container with full
root powers inside and no path to host root outside.

## Usage

```
sandbot-build                # build the sandbox image (once)
cd my-project                # per-project: bot name is derived from cwd
sandbot                      # creates container if missing, drops into bash
sandbot codex                # or run any other command
sandbot-destroy              # remove the container
sandbot-destroy-data         # remove the persisted agent state for this bot
```

Set `OPENAI_API_KEY` and/or `ANTHROPIC_API_KEY` in the shell before running
`sandbot` so the agents inside can authenticate. Set `SANDBOT_GPU=1` to give
the sandbox direct NVIDIA GPU access (note: GPU memory is not namespaced).

## Design

See `default.nix` and `Containerfile` for the implementation. The goals that
drive this design:

1. **Agents feel at home in a normal Linux.** `apt install`, `pip install`,
   `npm i`, `cargo install`, `curl | sh` all work. Root inside is expected.
2. **Host is protected.** Rootless podman + user-namespace remap means
   container root maps to an unprivileged host uid. Only `/workdir` (the
   project) and per-bot agent state dirs are bind-mounted in.
3. **Sandboxes are cheap.** `sandbot-create` starts a fresh container in
   seconds; `sandbot-destroy` + recreate yields a clean slate. The image
   is built once and reused across every project on the host.
4. **Project and agent memory persist; rootfs does not.** `/workdir` is a
   bind mount. Per-bot dirs under `$XDG_STATE_HOME/sandbot/<bot>` hold the
   agent's conversation history and caches. Everything else (including
   anything `apt install`ed during a session) is ephemeral -- recreate the
   container to get a clean slate.
5. **Image contents are pinned and auditable.** Debian base is pinned by
   manifest digest. Agent CLIs are pinned by upstream release URL + sha256
   (see `agent-versions.env`). Apt packages are accepted as Debian's choice
   within the pinned base image's release.

## Layout

```
agent-versions.env  # pinned versions + sha256s + URLs for every agent CLI
Containerfile       # multi-stage image build
default.nix         # host-side CLI scripts (sandbot*, sandbot-build)
scripts/            # files baked into the image (codex-wrapper, cexec)
nix/                # niv-pinned nixpkgs (only used for host podman)
```

## Bumping an agent CLI

1. Edit `agent-versions.env`: update VERSION, URL, and SHA256 for the tool.
2. Compute the new SHA256:
   ```
   nix-prefetch-url --type sha256 <new-url> | xargs nix-hash --type sha256 --to-base16
   ```
3. Rerun `sandbot-build`.

## Capability posture

Container runs with podman's default capability set plus `SYS_PTRACE` so
agents can run `strace` / `gdb`. Combined with `--userns=auto` and
`--security-opt=no-new-privileges`, the blast radius of anything inside is
limited to the container's own user namespace. See the comments in
`default.nix` on `sandbot-create` for details.

## Removed in this redesign

The previous iteration built a Nix-derived layered OCI image with nix itself
baked in, for "pinned + cached packages on the host." Problems:

- Agents inside had no ergonomic way to install anything (`apt`/`pip`/`npm`
  all missing; in-container `nix` was non-functional).
- Image rebuild required editing `default.nix` and re-streaming the image.
- A bespoke `codex.nix` + pid1 patch was needed because codex-rs had no
  prebuilt Linux binaries at the time. Both are obsolete now.

The current design drops all of that in favor of a standard Debian rootfs
and moves Nix to host-side tooling only.
