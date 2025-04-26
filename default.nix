let
  nixpkgs_src = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/5cfaab2c5c1492cbec3e5e85a4dca8601858a06a.tar.gz";
    sha256 = "sha256:13fs75rars50m49ngxbnk1ms4k2gv7ll9zwf6y64wlvpzw44vwnr";
  };
  pkgs = import nixpkgs_src { };
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

  policyObj = {
    default = [ { type = "insecureAcceptAnything"; } ];
  };
  policyFile = pkgs.writeText "podman-policy.json" (builtins.toJSON policyObj);

  image_packages = [
    (make_codex pkgs)
    pkgs.cargo
    pkgs.git
    pkgs.curl
    pkgs.dnsutils
    pkgs.fzf
    pkgs.gh
    pkgs.gnupg
    pkgs.jq
    pkgs.less
    pkgs.man-db
    pkgs.procps
    pkgs.unzip
    pkgs.ripgrep
    pkgs.bash
    pkgs.coreutils-full
    pkgs.clang
    pkgs.gnused
    pkgs.gawk
    pkgs.python3
    pkgs.gnugrep
    pkgs.file
    pkgs.findutils
    pkgs.just
  ];

  image_extras = [
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    pkgs.dockerTools.fakeNss
    empty_tmpdir
  ];

  empty_tmpdir = (
    pkgs.stdenv.mkDerivation {
      name = "tmp";
      buildCommand = ''
        mkdir -p $out/tmp
      '';
    }
  );
  env = pkgs.buildEnv {
    name = "dev-packages";
    paths = image_packages ++ image_extras;
  };

  sandbot-load = pkgs.writeShellScriptBin "sandbot-load" ''
    # #!/usr/bin/env bash
    set -ueo pipefail
    "${pkgs.gzip}/bin/gunzip" <${container} | "${pkgs.podman}/bin/podman" load --signature-policy ${policyFile}
  '';
  sandbot-run = pkgs.writeShellScriptBin "sandbot-run" ''
    #!/usr/bin/env bash
    set -ueo pipefail
    "${pkgs.podman}/bin/podman" run --signature-policy ${policyFile} --rm -it -e OPENAI_API_KEY -v "$(pwd):/workdir" "sandbot-devshell:sandbot-devshell" codex --full-auto --model o3
  '';

  container = pkgs.dockerTools.buildImage {
    name = "sandbot-devshell";
    tag = "sandbot-devshell";
    copyToRoot = env;
    config = {
      WorkingDir = "/workdir";
      Env = [
        "PATH=/usr/local/bin:/usr/bin:/bin"
        "CARGO_TARGET_DIR=/tmp/target"
      ];
    };
  };
in
pkgs.symlinkJoin {
  name = "sandbot";
  paths = [
    sandbot-load
    sandbot-run
  ];
}
