{...}: {
  flake.homeModules.shared = {
    pkgs,
    flake,
    lib,
    config,
    ...
  }: {
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
            records = config.home.username != "simon.riezebos";
          };
        };
      };
      bat.enable = true;
      broot.enable = true;
      btop.enable = true;
      direnv = {
        enable = true;
        config = {
          global.load_dotenv = true;
          whitelist.prefix = [
            "${config.home.homeDirectory}/repos"
          ];
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

        settings = {
          user.name = "Simon Riezebos";
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
          ".claude/settings.local.json"
        ];
        includes = [
          {
            path = "~/repos/.gitconfig";
            condition = "gitdir:~/repos/";
          }
          {
            path = "~/repos/volt/.gitconfig";
            condition = "gitdir:~/repos/volt/";
          }
        ];
      };
      jq.enable = true;
      oh-my-posh = {
        enable = true;
        # useTheme = "powerlevel10k_rainbow";
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
        initContent = lib.mkAfter ''
          export PATH="$HOME/.cargo/bin:$PATH"
          export PATH="$HOME/.local/bin:$PATH"
          export PATH="$HOME/.rd/bin:$PATH"

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

          ${lib.optionalString pkgs.stdenv.isDarwin ''
            # Foundry (Hetzner) LUKS unlock helpers.
            # Seed the macOS Keychain once:
            #     foundry-unlock-seed
            # Then, after a reboot, unlock the server in one step:
            #     foundry-unlock
            #
            # Requires a `Host foundry` entry in ~/.ssh/config — the IP is looked
            # up via `ssh -G` so it never appears in this (public) repo.
            #
            # The initrd sshd uses `ForceCommand systemd-tty-ask-password-agent --query`,
            # which reads the passphrase from /dev/tty. `ssh -tt` forces pty allocation
            # so the piped stdin is fed into the pty that the agent reads from.
            foundry-unlock() {
                emulate -L zsh
                local ssh_host=foundry
                # Keep in sync with services.openssh.ports in
                # modules/hosts/foundry/configuration.nix. The main sshd lives
                # on a non-standard port so the production system and Hetzner
                # rescue (always on :22) have disjoint host-key state; port
                # 2222 is the initrd LUKS-unlock sshd.
                local main_port=62222
                local ip pw rc
                ip=$(ssh -G "$ssh_host" 2>/dev/null | awk '/^hostname /{print $2; exit}')
                if [[ -z "$ip" || "$ip" == "$ssh_host" ]]; then
                    print -u2 "foundry-unlock: '$ssh_host' is not configured in ~/.ssh/config."
                    print -u2 "  Add a 'Host foundry' block with HostName set to the server IP and Port $main_port."
                    return 1
                fi
                if nc -z -G 2 "$ip" "$main_port" >/dev/null 2>&1; then
                    print "foundry: already up (port $main_port open). Nothing to do."
                    return 0
                fi
                if ! pw=$(security find-generic-password -a foundry -s foundry-luks -w 2>/dev/null); then
                    print -u2 "foundry-unlock: keychain item 'foundry-luks' not found."
                    print -u2 "  Seed it once with: foundry-unlock-seed"
                    return 1
                fi
                print "foundry: sending passphrase to initrd on $ssh_host:2222..."
                printf '%s\n' "$pw" | ssh -tt -p 2222 \
                    -o IdentitiesOnly=yes \
                    -o ConnectTimeout=10 \
                    -o ServerAliveInterval=5 \
                    -o StrictHostKeyChecking=accept-new \
                    "root@$ssh_host" >/dev/null 2>&1
                rc=$?
                pw=""
                if [[ $rc -ne 0 ]]; then
                    print -u2 "foundry-unlock: ssh to initrd returned $rc (wrong passphrase? initrd not up?)"
                    return $rc
                fi
                print "foundry: passphrase accepted, waiting for sshd on :$main_port..."
                local i
                for i in $(seq 1 60); do
                    if nc -z -G 2 "$ip" "$main_port" >/dev/null 2>&1; then
                        print "foundry: up."
                        return 0
                    fi
                    sleep 2
                done
                print -u2 "foundry: port $main_port still closed after 120s — check the console."
                return 2
            }
          ''}

          # Crash forensics without touching the server. Pulls the latest
          # snapshot of /var/log/journal from the Storage Box (via the
          # admin credential — separate from the append-only key foundry
          # holds) and opens journalctl --file against the restored
          # directory. Any journalctl args passed through: e.g.
          #     foundry-logs -u foundryvtt --since -1h
          #     foundry-logs -p err -n 200
          # Prompts once for the restic repo password (same string stored
          # in sops on the server); the input is hidden and never touches
          # disk outside a 0600 tmpfile that is wiped by the EXIT trap.
          foundry-logs() {
              emulate -L zsh
              local tmpdir
              tmpdir=$(mktemp -d /tmp/foundry-journal-XXXXXX) || return
              trap "rm -rf '$tmpdir'" EXIT INT TERM
              local ssh_cmd="ssh -p 23 -i $HOME/.config/foundry-bootstrap/storagebox_adm -o IdentitiesOnly=yes u580408-sub2@u580408-sub2.your-storagebox.de"
              local pw_file="$tmpdir/pw"
              local pw
              print -n "foundry-logs: restic repo password: "
              if ! IFS= read -rs pw; then
                  print
                  print -u2 "foundry-logs: could not read password."
                  return 1
              fi
              print
              if [[ -z "$pw" ]]; then
                  print -u2 "foundry-logs: empty password, aborting."
                  return 1
              fi
              umask 077
              printf '%s' "$pw" > "$pw_file"
              pw=""
              # Explicit --path filter. The Storage Box's forced command
              # chroots both subaccount URLs to the same `/foundry` dir, so
              # `rclone:storagebox:foundry` and `rclone:storagebox:foundry-journal`
              # resolve to a single underlying restic repo. `--path` on
              # restore is a snapshot selector (pick the newest snapshot
              # whose `paths` field contains the given path) — here it
              # picks the latest journal snapshot rather than the daily
              # 8 GB one. No --include needed: journal snapshots carry
              # exactly one path, so the selector and the extracted tree
              # are already the same.
              if ! nix run nixpkgs#restic -- \
                  -o "rclone.program=$ssh_cmd" \
                  -r rclone:storagebox:foundry-journal \
                  --password-file "$pw_file" \
                  restore latest \
                    --path /var/log/journal \
                    --target "$tmpdir" >/dev/null; then
                  print -u2 "foundry-logs: restic restore failed."
                  return 2
              fi
              local journals=("$tmpdir"/var/log/journal/*/*.journal(N))
              if (( ! $#journals )); then
                  print -u2 "foundry-logs: no .journal files found under the restored tree."
                  return 3
              fi
              journalctl \
                  --file "''${journals[@]}" \
                  --no-pager --output short-precise \
                  "$@"
          }

          ${lib.optionalString pkgs.stdenv.isDarwin ''
            foundry-unlock-seed() {
                print "Storing LUKS passphrase for foundry in the login keychain."
                print "(Input is hidden; you will be prompted once.)"
                security add-generic-password \
                    -a foundry \
                    -s foundry-luks \
                    -l "Foundry LUKS passphrase" \
                    -D "LUKS passphrase" \
                    -j "Used by foundry-unlock zsh function" \
                    -U \
                    -w
            }
          ''}

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

          #git
          gcl = "git clone";
          gpl = "git pull";
          gp = "git push";
          gpf = "git push --force";
          gcm = "git commit -m";
          gf = "git fetch --all --prune";
          gst = "git stash";
          gstp = "git stash pop";
          gsw = "git switch";
          gswc = "git switch -c";
          gswm = "git switch main";
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

    # sops' default age key location differs per-OS (macOS: ~/Library/…,
    # Linux: ~/.config/…). The `.sops.yaml` in this repo refers to the key
    # at ~/.config/sops/age/keys.txt — point sops at it explicitly so the
    # same path works on every machine.
    home.sessionVariables.SOPS_AGE_KEY_FILE = "${config.home.homeDirectory}/.config/sops/age/keys.txt";

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
      devenv
      nodejs_24
      glab
      crane
      cachix
      gh
      sops
      age
      ssh-to-age
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
      registry.nixpkgs.flake = flake.inputs.nixpkgs-devenv;
    };
  };
}
