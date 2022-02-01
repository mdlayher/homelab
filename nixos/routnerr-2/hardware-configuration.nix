# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "ahci" "ehci_pci" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/10be6bfd-9f03-4ce7-88b2-5d00691f728c";
    fsType = "ext4";
  };

  swapDevices =
    [{ device = "/dev/disk/by-uuid/56b049fa-6f09-4bc7-97e3-0c790cfa354a"; }];

  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;
}
