{ pkgs, ... }:
let
  codexSrc = pkgs.fetchFromGitHub {
    owner = "openai";
    repo = "codex";
    rev = "5268705a69713752adcbd8416ef9e84a683f7aa3";
    sha256 = "sha256-IBYx362R2ueYNg7/vcjGa2kKAfGlPm6JcZ/A4XKtMT4=";
  };
  codex = (import "${codexSrc}/codex-rs" { inherit pkgs; }).package;
  codexFixed = codex.overrideAttrs (prev: {
    cargoDeps = pkgs.rustPlatform.importCargoLock {
      lockFile = "${prev.src}/Cargo.lock";
      outputHashes = {
        "ratatui-0.29.0" =
          "sha256-HBvT5c8GsiCxMffNjJGLmHnvG77A6cqEL+1ARurBXho=";
      };
    };
  });
in codexFixed
