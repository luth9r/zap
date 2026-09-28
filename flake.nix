{
  description = "A minimalist shell prompt written in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      systemOutputs = flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };

          testBash = pkgs.writeShellScriptBin "test-bash" ''
            export PATH="${self.packages.${system}.default}/bin:$PATH"
            echo "󱐋 Starting interactive Bash with Zap prompt..."
            RC=$(mktemp)
            echo 'eval "$(${self.packages.${system}.default}/bin/zap init bash)"' > "$RC"
            exec ${pkgs.bashInteractive}/bin/bash --rcfile "$RC" -i
          '';

          testZsh = pkgs.writeShellScriptBin "test-zsh" ''
            export PATH="${self.packages.${system}.default}/bin:$PATH"
            echo "󱐋 Starting interactive Zsh with Zap prompt..."
            ZDIR=$(mktemp -d)
            echo 'eval "$(${self.packages.${system}.default}/bin/zap init zsh)"' > "$ZDIR/.zshrc"
            ZDOTDIR="$ZDIR" exec ${pkgs.zsh}/bin/zsh -i
          '';

          testFish = pkgs.writeShellScriptBin "test-fish" ''
            export PATH="${self.packages.${system}.default}/bin:$PATH"
            echo "󱐋 Starting interactive Fish with Zap prompt..."
            exec ${pkgs.fish}/bin/fish -C "${self.packages.${system}.default}/bin/zap init fish | source"
          '';

          testPwsh = pkgs.writeShellScriptBin "test-pwsh" ''
            export PATH="${self.packages.${system}.default}/bin:$PATH"
            echo "󱐋 Starting interactive PowerShell with Zap prompt..."
            exec ${pkgs.powershell}/bin/pwsh -NoExit -Command "(&${self.packages.${system}.default}/bin/zap init powershell | Out-String) | Invoke-Expression"
          '';

          testAll = pkgs.writeShellScriptBin "test-all" ''
            echo "󱐋 Running all Zap unit and integration tests..."
            exec ${pkgs.zig}/bin/zig build test
          '';
        in
        {
          packages = rec {
            zap = pkgs.stdenv.mkDerivation {
              pname = "zap";
              version = "1.0.0";
              src = ./.;

              nativeBuildInputs = [ pkgs.zig ];

              dontConfigure = true;

              buildPhase = ''
                runHook preBuild
                export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
                export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local-cache
                zig build -Doptimize=ReleaseFast --prefix $out
                runHook postBuild
              '';

              meta = with pkgs.lib; {
                description = "A minimalist shell prompt written in Zig";
                homepage = "https://github.com/luth9r/zap";
                license = licenses.mit;
                mainProgram = "zap";
                platforms = platforms.unix;
              };
            };

            default = zap;
          };

          apps = rec {
            default = flake-utils.lib.mkApp {
              drv = self.packages.${system}.default;
            };
            bash = flake-utils.lib.mkApp { drv = testBash; };
            zsh = flake-utils.lib.mkApp { drv = testZsh; };
            fish = flake-utils.lib.mkApp { drv = testFish; };
            pwsh = flake-utils.lib.mkApp { drv = testPwsh; };
            test = flake-utils.lib.mkApp { drv = testAll; };
          };

          devShells.default = pkgs.mkShell {
            name = "zap-dev-shell";

            packages = [
              self.packages.${system}.default
              testBash
              testZsh
              testFish
              testPwsh
              testAll
            ] ++ (with pkgs; [
              zig
              bashInteractive
              zsh
              fish
              powershell
              time
              git
            ]);

            shellHook = ''
              export PATH="$PWD/zig-out/bin:$PATH"
              export ZAP_DEV=1
              echo "󱐋 Welcome to Zap development shell!"
              echo "Quick test commands: test-bash, test-zsh, test-fish, test-pwsh, test-all"
            '';
          };
        }
      );
    in
    systemOutputs // {
      homeManagerModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.zap;
          tomlFormat = pkgs.formats.toml { };
        in
        {
          options.programs.zap = {
            enable = lib.mkEnableOption "zap minimalist shell prompt";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.default;
              description = "The zap package to install.";
            };

            settings = lib.mkOption {
              type = tomlFormat.type;
              default = { };
              description = "Configuration written to ~/.config/zap/config.toml";
              example = lib.literalExpression ''
                {
                  add_newline = true;
                  format = "$directory$git_branch$git_status$character";
                  directory = {
                    style = "bold cyan";
                    truncation_length = 3;
                  };
                  character = {
                    success_symbol = "[❯](bold green)";
                    error_symbol = "[❯](bold red)";
                  };
                }
              '';
            };

            enableBashIntegration = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to enable Bash integration.";
            };

            enableZshIntegration = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to enable Zsh integration.";
            };

            enableFishIntegration = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to enable Fish integration.";
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];

            xdg.configFile."zap/config.toml" = lib.mkIf (cfg.settings != { }) {
              source = tomlFormat.generate "zap-config.toml" cfg.settings;
            };

            programs.bash.initExtra = lib.mkIf cfg.enableBashIntegration ''
              eval "$(${cfg.package}/bin/zap init bash)"
            '';

            programs.zsh.initExtra = lib.mkIf cfg.enableZshIntegration ''
              eval "$(${cfg.package}/bin/zap init zsh)"
            '';

            programs.fish.interactiveShellInit = lib.mkIf cfg.enableFishIntegration ''
              ${cfg.package}/bin/zap init fish | source
            '';
          };
        };

      homeManagerModule = self.homeManagerModules.default;
    };
}
