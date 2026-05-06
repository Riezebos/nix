{inputs, ...}: {
  flake.nixosModules.agentSandcastleLauncher = {config, ...}: {
    # Only the launcher module — explicitly NOT `nixosModules.host`. The
    # `host` overlay drags microvm.nix + agent-sandcastle's pinned unstable
    # nixpkgs into the foundry pkgs set, but foundry isn't running KVM
    # sandboxes itself yet. Keep the surface minimal: just the Phoenix
    # release behind Caddy + Authentik.
    imports = [inputs.agent-sandcastle.nixosModules.launcher];

    services.agent-sandcastle.launcher = {
      enable = true;
      host = "sandcastle.simonito.com";
      # bindAddress (127.0.0.1) and port (4000) left at upstream defaults;
      # the Caddy vhost in modules/features/caddy.nix forwards there.
      environmentFile = config.sops.secrets."agent-sandcastle-launcher".path;
    };

    sops.secrets."agent-sandcastle-launcher" = {
      owner = "agent-sandcastle";
      group = "agent-sandcastle";
      mode = "0400";
      restartUnits = ["agent-sandcastle-launcher.service"];
    };
  };
}
