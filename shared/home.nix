{
  pkgs,
  lib,
  ...
}: {
  home.username = "simon";

  programs = {
    awscli.enable = true;
    atuin = {
      enable = true;
      settings = {
        sync_frequency = "5m";
        style = "compact";
        enter_accept = true;
        filter_mode_shell_up_key_binding = "directory";
        search_mode_shell_up_key_binding = "prefix";
        show_preview = false;
        show_tabs = false;
        ctrl_n_shortcuts = true;
        sync = {
          records = true;
        };
      };
    };
    bat.enable = true;
    broot.enable = true;
    btop.enable = true;
    direnv = {
      enable = true;
      silent = true;
      config = {
        global.load_dotenv = true;
      };
    };
    eza = {
      enable = true;
      git = true;
      icons = "auto";
      extraOptions = [
        "--group-directories-first"
        "--header"
      ];
    };
    fd = {
      enable = true;
      extraOptions = [
        "--no-ignore"
        "--absolute-path"
      ];
      ignores = [
        ".git"
        ".hg"
      ];
    };
    git = {
      enable = true;
      lfs.enable = true;

      userName = "Simon Riezebos";
      userEmail = "info@datagiant.org";
      extraConfig = {
        init.defaultBranch = "main";
        rerere.enabled = true;
        pull.rebase = true;
        push.autoSetupRemote = true;
        pack.sparse = true;
        core.editor = "cursor --wait";
      };
      ignores = [
        ".DS_Store"
        "temp.ipynb"
        "my_local_files/"
      ];
      includes = [
        {
          path = "~/repos/volt/.gitconfig";
          condition = "gitdir:~/repos/volt/";
        }
      ];
    };
    jq.enable = true;
    # starship = {
    #   enable = true;
    #   settings = {
    #     command_timeout = 10000;
    #     add_newline = true;
    #     line_break.disabled = false;

    #     format = lib.strings.concatStrings [
    #       "$hostname"
    #       "[](#DA627D)"
    #       "$directory"
    #       "[](fg:#DA627D bg:#FCA17D)"
    #       "$git_branch"
    #       "$git_status"
    #       "[](fg:#FCA17D bg:#86BBD8)"
    #       "$python"
    #       "$conda"
    #       "$terraform"
    #       "$c"
    #       "$elixir"
    #       "$elm"
    #       "$golang"
    #       "$gradle"
    #       "$haskell"
    #       "$java"
    #       "$julia"
    #       "$nodejs"
    #       "$nim"
    #       "$rust"
    #       "$scala"
    #       "[](fg:#86BBD8 bg:#06969A)"
    #       "$cmd_duration"
    #       "[](#06969A)"
    #       "\n$character"
    #     ];

    #     aws.disabled = true;
    #     gcloud.disabled = true;

    #     cmd_duration.format = "[⏲ $duration]($style)";
    #     cmd_duration.style = "bg:#06969a";

    #     username = {
    #       show_always = false;
    #       style_user = "bg:#9a348e";
    #       style_root = "bg:#9a348e";
    #       format = "[ $user ]($style)";
    #       disabled = true;
    #     };

    #     directory = {
    #       style = "bg:#DA627D";
    #       format = "[ $path ]($style)";
    #       substitutions = {
    #         "Documents" = "󰈙 ";
    #         "Downloads" = " ";
    #         "Music" = " ";
    #         "Pictures" = " ";
    #       };
    #     };

    #     c = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     docker_context = {
    #       symbol = " ";
    #       style = "bg:#06969A";
    #       format = "[ $symbol $context ]($style) $path";
    #     };

    #     elixir = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     elm = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     git_branch = {
    #       symbol = " ";
    #       style = "bg:#FCA17D";
    #       format = "[$symbol$branch ]($style)";
    #     };

    #     git_status = {
    #       style = "bg:#FCA17D";
    #       format = "[$all_status$ahead_behind]($style)";
    #       ahead = "⇡$count";
    #       diverged = "⇡$ahead_count⇣$behind_count";
    #       behind = "⇣$count";
    #       conflicted = "≠";
    #       up_to_date = "✓";
    #       untracked = "…";
    #       stashed = "⚑";
    #       modified = "+";
    #     };

    #     golang = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     gradle = {
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     haskell = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     hostname = {
    #       ssh_only = true;
    #       format = "[$ssh_symbol$hostname ]($style)";
    #       ssh_symbol = "🌐";
    #     };

    #     java = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     julia = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     python = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol$pyenv_prefix($version) ($virtualenv)]($style)";
    #     };

    #     nodejs = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version)]($style)";
    #     };

    #     nim = {
    #       symbol = "󰆥 ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     rust = {
    #       symbol = "";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     scala = {
    #       symbol = " ";
    #       style = "bg:#86BBD8";
    #       format = "[$symbol($version) ]($style)";
    #     };

    #     time = {
    #       disabled = false;
    #       time_format = "%R";
    #       style = "bg:#33658A";
    #       format = "[ ♥ $time ]($style)";
    #     };
    #   };
    # };
    oh-my-posh = {
      enable = true;
      useTheme = "powerlevel10k_rainbow";
      settings = {
        final_space = true;
        shell_integration = true;
        enable_cursor_positioning = true;
        iterm_features = [
          "remote_host"
          "current_dir"
          # "prompt_mark"
        ];
        # below part is mostly this file converted to nix with json2nix: https://github.com/JanDeDobbeleer/oh-my-posh/blob/main/themes/powerlevel10k_rainbow.omp.json
        # and then applying a strange workaround to make unicode characters work: https://github.com/NixOS/nix/issues/10082#issuecomment-2059228774
        blocks = [
          {
            alignment = "left";
            segments = [
              {
                background = "#d3d7cf";
                foreground = "#000000";
                # leading_diamond = builtins.fromJSON ''"\u256d\u2500\ue0b2"'';
                style = "diamond";
                template = " {{ if .WSL }}WSL at {{ end }}{{.Icon}} ";
                type = "os";
              }
              {
                background = "#3465a4";
                foreground = "#e4e4e4";
                powerline_symbol = builtins.fromJSON ''"\ue0b0"'';
                properties = {
                  home_icon = "~";
                  style = "full";
                };
                style = "powerline";
                template = builtins.fromJSON ''" \uf07c {{ .Path }} "'';
                type = "path";
              }
              {
                background = "#4e9a06";
                background_templates = [
                  "{{ if or (.Working.Changed) (.Staging.Changed) }}#c4a000{{ end }}"
                  "{{ if and (gt .Ahead 0) (gt .Behind 0) }}#f26d50{{ end }}"
                  "{{ if gt .Ahead 0 }}#89d1dc{{ end }}"
                  "{{ if gt .Behind 0 }}#4e9a06{{ end }}"
                ];
                foreground = "#000000";
                powerline_symbol = builtins.fromJSON ''"\ue0b0"'';
                properties = {
                  branch_icon = builtins.fromJSON ''"\uf126 "'';
                  fetch_stash_count = true;
                  fetch_status = true;
                  fetch_upstream_icon = true;
                };
                style = "powerline";
                template = builtins.fromJSON ''" {{ .UpstreamIcon }}{{ .HEAD }}{{if .BranchStatus }} {{ .BranchStatus }}{{ end }}{{ if .Working.Changed }} \uf044 {{ .Working.String }}{{ end }}{{ if and (.Working.Changed) (.Staging.Changed) }} |{{ end }}{{ if .Staging.Changed }} \uf046 {{ .Staging.String }}{{ end }}{{ if gt .StashCount 0 }} \ueb4b {{ .StashCount }}{{ end }} "'';
                type = "git";
              }
            ];
            type = "prompt";
          }
          {
            alignment = "right";
            segments = [
              {
                background = "#689f63";
                foreground = "#ffffff";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                properties = {
                  fetch_version = true;
                };
                style = "powerline";
                template = builtins.fromJSON ''" {{ if .PackageManagerIcon }}{{ .PackageManagerIcon }} {{ end }}{{ .Full }} \ue718 "'';
                type = "node";
              }
              {
                background = "#00acd7";
                foreground = "#111111";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                properties = {
                  fetch_version = true;
                };
                style = "powerline";
                template = builtins.fromJSON ''" {{ if .Error }}{{ .Error }}{{ else }}{{ .Full }}{{ end }} \ue627 "'';
                type = "go";
              }
              {
                background = "#4063D8";
                foreground = "#111111";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                properties = {
                  fetch_version = true;
                };
                style = "powerline";
                template = builtins.fromJSON ''" {{ if .Error }}{{ .Error }}{{ else }}{{ .Full }}{{ end }} \ue624 "'';
                type = "julia";
              }
              {
                background = "#FFDE57";
                foreground = "#111111";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                properties = {
                  display_mode = "files";
                  fetch_virtual_env = false;
                };
                style = "powerline";
                template = builtins.fromJSON ''" {{ if .Error }}{{ .Error }}{{ else }}{{ .Full }}{{ end }} \ue235 "'';
                type = "python";
              }
              {
                background = "#AE1401";
                foreground = "#ffffff";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                properties = {
                  display_mode = "files";
                  fetch_version = true;
                };
                style = "powerline";
                template = builtins.fromJSON ''" {{ if .Error }}{{ .Error }}{{ else }}{{ .Full }}{{ end }} \ue791 "'';
                type = "ruby";
              }
              {
                background = "#FEAC19";
                foreground = "#ffffff";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                properties = {
                  display_mode = "files";
                  fetch_version = false;
                };
                style = "powerline";
                template = builtins.fromJSON ''" {{ if .Error }}{{ .Error }}{{ else }}{{ .Full }}{{ end }} \uf0e7"'';
                type = "azfunc";
              }
              {
                background_templates = [
                  "{{if contains \"default\" .Profile}}#FFA400{{end}}"
                  "{{if contains \"jan\" .Profile}}#f1184c{{end}}"
                ];
                foreground = "#ffffff";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                properties = {
                  display_default = false;
                };
                style = "powerline";
                template = builtins.fromJSON ''" {{ .Profile }}{{ if .Region }}@{{ .Region }}{{ end }} \ue7ad "'';
                type = "aws";
              }
              {
                background = "#ffff66";
                foreground = "#111111";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                style = "powerline";
                template = builtins.fromJSON ''" \uf0ad "'';
                type = "root";
              }
              {
                background = "#c4a000";
                foreground = "#000000";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                style = "powerline";
                template = builtins.fromJSON ''" {{ .FormattedMs }} \uf252 "'';
                type = "executiontime";
              }
              {
                background = "#000000";
                background_templates = [
                  "{{ if gt .Code 0 }}#cc2222{{ end }}"
                ];
                foreground = "#d3d7cf";
                invert_powerline = true;
                powerline_symbol = builtins.fromJSON ''"\ue0b2"'';
                properties = {
                  always_enabled = true;
                };
                style = "powerline";
                template = builtins.fromJSON ''" {{ if gt .Code 0 }}{{ reason .Code }}{{ else }}\uf42e{{ end }} "'';
                type = "status";
              }
              {
                background = "#d3d7cf";
                foreground = "#000000";
                invert_powerline = true;
                style = "diamond";
                template = builtins.fromJSON ''" {{ .CurrentDate | date .Format }} \uf017 "'';
                # trailing_diamond = builtins.fromJSON ''"\ue0b0\u2500\u256e"'';
                type = "time";
              }
            ];
            type = "prompt";
          }
          {
            alignment = "left";
            newline = true;
            segments = [
              {
                foreground = "#81ff91";
                foreground_templates = ["{{if gt .Code 0}}#ff3030{{end}}"];
                style = "diamond";
                template = builtins.fromJSON ''"\u276f"'';
                properties.always_enabled = true;
                type = "text";
              }
            ];
            type = "prompt";
          }
        ];
        console_title_template = "{{ .Shell }} in {{ .Folder }}";
        version = 3;
      };
    };
    pandoc.enable = true;
    ripgrep = {
      enable = true;
      arguments = [
        "--max-columns=150"
        "--max-columns-preview"
        "--hidden"
        "--glob=!.git/*"
        "--smart-case"
      ];
    };
    tealdeer = {
      enable = true;
      settings.updates.auto_update = true;
    };
    zoxide.enable = true;
    zsh = {
      enable = true;
      autocd = true;
      syntaxHighlighting.enable = true;
      autosuggestion.enable = true;
      history = {
        append = true;
        ignoreDups = true;
        ignoreAllDups = true;
        ignoreSpace = false;
      };
      initExtra = lib.mkAfter ''
        export PATH="$HOME/.cargo/bin:$PATH"
        export PATH="$HOME/repos/experiments/flutter/bin:$PATH"
        export GEM_HOME=$HOME/.gem
        export PATH=$GEM_HOME/bin:$PATH
        export PATH="$HOME/.gem/ruby/3.3.0/bin:$PATH"
        export PATH="$HOME/.local/bin:$PATH"

        export PIP_REQUIRE_VIRTUALENV=1
        export PIP_USE_PEP517=1
        export MANPAGER="sh -c 'col -bx | bat -l man -p'"
        export LANG="en_US.UTF-8"
        export LC_CTYPE="en_US.UTF-8"
        export LC_ALL="en_US.UTF-8"
        export LANGUAGE="en_US.UTF-8"

        _zsh_autosuggest_strategy_atuin_auto() {
            suggestion=$(atuin search --cwd . --cmd-only --limit 1 --search-mode prefix -- "$1")
        }

        _zsh_autosuggest_strategy_atuin_global() {
            suggestion=$(atuin search --cmd-only --limit 1 --search-mode prefix -- "$1")
        }
        export ZSH_AUTOSUGGEST_STRATEGY=(atuin_auto atuin_global)

        pip() {
            if ! type -P pip &> /dev/null
            then
                uv pip "$@"
            else
                command pip "$@"
            fi
        }

        bindkey "^ " autosuggest-accept
        test -e "$HOME/.iterm2_shell_integration.zsh" && source "$HOME/.iterm2_shell_integration.zsh"
      '';

      shellAliases = {
        venv = "source .venv/bin/activate";
        helpme = "tldr --list | fzf | xargs tldr";
        gcs = "gcloud storage";
        cat = "bat -pP";
        ur = "uv run";
        hm-mac = "home-manager switch --flake /Users/simon/repos/nix#simon-darwin";
        hm-pega = "ssh pegalite 'source /etc/bashrc && cd ~/repos/nix && git pull && home-manager switch --flake ~/repos/nix#simon-linux'";
      };
      plugins = [
        {
          name = "fzf-tab";
          src = pkgs.fetchFromGitHub {
            owner = "Aloxaf";
            repo = "fzf-tab";
            rev = "c2b4aa5ad2532cca91f23908ac7f00efb7ff09c9";
            sha256 = "1b4pksrc573aklk71dn2zikiymsvq19bgvamrdffpf7azpq6kxl2";
          };
        }
      ];
    };
  };

  home.packages = with pkgs; [
    alejandra
    # No idea how to get the az ml extension to work
    # (azure-cli.withExtensions [
    #   azure-cli.extensions.azure-devops
    # ])
    curl
    ffmpeg
    fzf
    font-awesome
    google-cloud-sdk
    graphviz
    imagemagick
    material-design-icons
    nerd-fonts.caskaydia-cove
    nerd-fonts.fantasque-sans-mono
    nil
    rsync
    nodejs
  ];

  home.file.".ipython/profile_default/ipython_config.py".text = ''
    c = get_config()

    c.InteractiveShell.ast_node_interactivity = "all"
    c.InteractiveShellApp.exec_lines = ["%autoreload 2"]
    c.InteractiveShellApp.extensions = ["autoreload"]
  '';

  home.stateVersion = "24.11";
  nixpkgs.config.allowUnfree = true;
  fonts.fontconfig.enable = true;
  programs.home-manager.enable = true;

  nix = {
    package = pkgs.nix;
    settings.experimental-features = ["nix-command" "flakes"];
  };

  # below is needed for Spotlight but Raycast is smart enough to read symlinks
  # home.activation = {
  #   aliasHomeManagerApplications = lib.hm.dag.entryAfter [ "writeBoundary" ] ""
  #     app_folder="${config.home.homeDirectory}/Applications/Home Manager Apps"
  #     rm -rf "$app_folder"
  #     mkdir -p "$app_folder"
  #     for app in $(find "$genProfilePath/home-path/Applications" -type l); do
  #         app_target="$app_folder/$(basename $app)"
  #         real_app="$(readlink $app)"
  #         echo "mkalias \"$real_app\" \"$app_target\"" >&2
  #         $DRY_RUN_CMD ${pkgs.mkalias}/bin/mkalias "$real_app" "$app_target"
  #     done
  #   "";
  # };
}
