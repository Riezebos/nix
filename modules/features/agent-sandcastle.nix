{inputs, ...}: {
  # Development sandboxes are managed with `sudo sandcastle ...` over SSH.
  flake.nixosModules.agentSandcastleCli = {...}: {
    imports = [inputs.agent-sandcastle.nixosModules.sandcastleHost];

    services.sandcastle = {
      enable = true;

      # Sandbox web routes must be subdomains of this zone. Wildcard DNS for
      # *.simonito.com already resolves here, so a route only needs a Caddy
      # snippet. Route management itself is not implemented upstream yet.
      routeZone = "simonito.com";

      subnet = "10.88.0.0/24";

      # The network module reserves .100 through .254 for DHCP, so keep the
      # CLI's static pool below it.
      allocationEnd = "10.88.0.99";

      # Foundry runs Foundry VTT, Authentik, PostgreSQL, and the monitoring
      # stack besides this. Sandboxes default to 2304 MiB each, so four
      # concurrent guests is about 9 GiB of the 64 GiB box. The CLI refuses to
      # start a fifth rather than letting the host swap.
      maxRunning = 4;
    };

    # Bridge, DNS, NAT, and egress filtering for the sandbox network.
    services.agent-sandcastle.networking.enable = true;
  };
}
