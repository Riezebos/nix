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

  # The CLI-first replacement for the launcher: `sudo sandcastle ...` over SSH
  # instead of a Phoenix web UI. Deployed *alongside* the launcher on purpose.
  # Upstream's migration plan builds the replacement first and only removes
  # Phoenix, Happy, the launcher secret, and the curated store once this has
  # passed its acceptance checklist on this box.
  flake.nixosModules.agentSandcastleCli = {...}: {
    imports = [inputs.agent-sandcastle.nixosModules.sandcastleHost];

    services.sandcastle = {
      enable = true;

      # Sandbox web routes must be subdomains of this zone. Wildcard DNS for
      # *.simonito.com already resolves here, so a route only needs a Caddy
      # snippet. Route management itself is not implemented upstream yet.
      routeZone = "simonito.com";

      # The sandbox bridge this shares with the launcher leases 10.88.0.100
      # through .254 over DHCP to the declarative VMs, so the CLI's *static*
      # pool has to stop below that range. Without this, dnsmasq could lease
      # an address a CLI sandbox already owns statically.
      allocationEnd = "10.88.0.99";

      # Foundry runs Foundry VTT, Authentik, PostgreSQL, and the monitoring
      # stack besides this. Sandboxes default to 2304 MiB each, so four
      # concurrent guests is about 9 GiB of the 64 GiB box. The CLI refuses to
      # start a fifth rather than letting the host swap.
      maxRunning = 4;
    };
  };
}
