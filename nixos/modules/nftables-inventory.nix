# nftables set elements from inventory secrets, loaded from a rendered file
# once the ruleset is in place. Empty sets fail closed; a rule that must
# fail open goes in the file, into a chain the ruleset declares empty.
#
# The file flushes each set and chain before filling it, so changed values
# replace old ones and a rerun repeats nothing. nft applies it as one
# transaction.
#
# Importers set homelab.nftablesInventory.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab.nftablesInventory;
  nft = "${pkgs.nftables}/bin/nft";
  elementsFile = config.sops.templates."nftables-inventory.conf".path;
in
{
  options.homelab.nftablesInventory = lib.mkOption {
    type = lib.types.lines;
    description = ''
      nft commands filling the ruleset's inventory sets, with sops
      placeholders for their elements.
    '';
  };

  options.homelab.mgmtLockdown.enforce = lib.mkOption {
    type = lib.types.bool;
    description = ''
      Whether mgmt_inventory drops unknown management LAN hosts. When
      false it only logs and counts them.
    '';
  };

  config = {
    sops.templates."nftables-inventory.conf".content = cfg;

    # Load inventory set elements after the ruleset is (re)loaded, since loading
    # the ruleset flushes all sets, and after the secrets are installed: sops
    # restarts a template's restartUnits before it swaps /run/secrets to the
    # newly rendered files, so a unit restarted that way reads the previous
    # contents and reports success. Binding to the installer's unit runs this
    # once the new file is in place, and only when a rendered file changed.
    systemd.services.nftables-inventory = {
      description = "nftables inventory set elements";
      after = [
        "nftables.service"
        "sops-install-secrets.service"
      ];
      requires = [ "nftables.service" ];
      partOf = [
        "nftables.service"
        "sops-install-secrets.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${nft} -f ${elementsFile}";
      };
    };
    systemd.services.nftables.serviceConfig.ExecReload = lib.mkAfter [ "${nft} -f ${elementsFile}" ];
  };
}
