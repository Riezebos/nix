{inputs, ...}: {
  flake.nixosModules.agentSandcastleLauncher = {config, ...}: {
    imports = [
      inputs.agent-sandcastle.nixosModules.host
      inputs.agent-sandcastle.nixosModules.launcher
    ];

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

    services.agent-sandcastle.networking.enable = true;

    services.agent-sandcastle.sandboxStore = {
      enable = true;
      closureRoots = [
        config.microvm.vms.sandcastle-smoke.config.config.system.build.toplevel
        config.microvm.vms.sandcastle-smoke.config.config.microvm.declaredRunner
      ];
    };

    microvm.vms.sandcastle-smoke = {
      autostart = false;
      config = inputs.agent-sandcastle.lib.mkSandbox {
        name = "sandcastle-smoke";
        networkMode = "tap";
        useCuratedStore = true;
        diskSizeMiB = 2048;
        authorizedKeys = config.users.users.simon.openssh.authorizedKeys.keys;
      };
    };
  };
}
