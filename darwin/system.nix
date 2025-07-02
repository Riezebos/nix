{
  pkgs,
  lib,
  ...
}: {
  # This is needed for home-manager to work
  users.users.simon = {home = "/Users/simon";};

  # mkalias can be used to create aliases instead of symlinks for Spotlight
  # environment.systemPackages = [pkgs.mkalias];

  # add nix stuff to /etc/zshrc
  programs.zsh.enable = true;

  # seems to be broken in unstable, something with the kitty theme and base16 vs base24
  # stylix = {
  #   enable = true;
  #   autoEnable = true;
  #   polarity = "dark";
  #   image = pkgs.fetchurl {
  #     url = "https://www.pixelstalk.net/wp-content/uploads/2016/05/Epic-Anime-Awesome-Wallpapers.jpg";
  #     sha256 = "enQo3wqhgf0FEPHj2coOCvo7DuZv+x5rL/WIo4qPI50=";
  #   };
  #   fonts = {
  #     sizes = {
  #       applications = 14;
  #       desktop = 14;
  #       popups = 14;
  #       terminal = 14;
  #     };
  #     monospace = {
  #       name = "CaskaydiaCove Nerd Font Mono";
  #       package = pkgs.nerdfonts.override {fonts = ["CascadiaCode"];};
  #     };
  #     sansSerif = {
  #       name = "Ubuntu";
  #       package = pkgs.ubuntu_font_family;
  #     };
  #     serif = config.stylix.fonts.sansSerif;
  #     emoji = {
  #       package = pkgs.noto-fonts-emoji;
  #       name = "Noto Color Emoji";
  #     };
  #   };
  # };

  nix = {
    enable = true;
    # update nix to the latest version
    package = pkgs.nix;

    # clean the nix store
    gc = {
      automatic = lib.mkDefault true;
      options = lib.mkDefault "--delete-older-than 7d";
    };

    settings = {
      # Necessary for using flakes on this system.
      experimental-features = ["nix-command" "flakes"];

      # Cachix is apparently a cache that most people use, but putting it here does not seem to do a lot
      substituters = ["https://nix-community.cachix.org"];
      trusted-public-keys = ["nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="];
      builders-use-substitutes = true;
      extra-substituters = "https://devenv.cachix.org";
      extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    };
  };

  # hostplatform is just macbook for now
  nixpkgs.hostPlatform = "aarch64-darwin";

  # enable sudo with touch id
  security.pam.services.sudo_local.touchIdAuth = true;

  # set some system defaults
  system = {
    #   defaults = {
    # dock.autohide = true;
    # dock.largesize = 64;
    # dock.persistent-apps = [
    #   "${pkgs.alacritty}/Applications/Alacritty.app"
    #   "/Applications/Firefox.app"
    #   "${pkgs.obsidian}/Applications/Obsidian.app"
    #   "/System/Applications/Mail.app"
    #   "/System/Applications/Calendar.app"
    # ];
    # finder.FXPreferredViewStyle = "clmv";
    # loginwindow.GuestEnabled = false;
    # NSGlobalDomain.AppleICUForce24HourTime = true;
    # NSGlobalDomain.AppleInterfaceStyle = "Dark";
    # NSGlobalDomain.KeyRepeat = 2;
    # };

    # Used for backwards compatibility, please read the changelog before changing.
    # $ darwin-rebuild changelog
    stateVersion = 5;
    # activationScripts.postUserActivation.text = ''
    #   # activateSettings -u will reload the settings from the database and apply them to the current session,
    #   # so we do not need to logout and login again to make the changes take effect.
    #   /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    # '';

    # below is needed for Spotlight but Raycast is smart enough to read symlinks
    # activationScripts.applications.text = let
    #   env = pkgs.buildEnv {
    #     name = "system-applications";
    #     paths = config.environment.systemPackages;
    #     pathsToLink = "/Applications";
    #   };
    # in
    #   lib.mkForce ''
    #     # Set up applications.
    #     echo "setting up /Applications..." >&2
    #     rm -rf /Applications/Nix\ Apps
    #     mkdir -p /Applications/Nix\ Apps
    #     find ${env}/Applications -maxdepth 1 -type l -exec readlink '{}' + |
    #     while read src; do
    #       app_name=$(basename "$src")
    #       echo "copying $src" >&2
    #       ${pkgs.mkalias}/bin/mkalias "$src" "/Applications/Nix Apps/$app_name"
    #     done
    #   '';
  };
}
