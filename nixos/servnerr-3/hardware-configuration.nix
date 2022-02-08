# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules =
    [ "nvme" "xhci_pci" "ahci" "mpt3sas" "uas" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/bab1720c-5d05-4d95-8a7e-8d22ee9327f1";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/9FA3-7F58";
    fsType = "vfat";
  };

  fileSystems."/primary" = {
    device = "primary";
    fsType = "zfs";
  };

  fileSystems."/primary/vm" = {
    device = "primary/vm";
    fsType = "zfs";
  };

  fileSystems."/primary/misc" = {
    device = "primary/misc";
    fsType = "zfs";
  };

  fileSystems."/primary/media" = {
    device = "primary/media";
    fsType = "zfs";
  };

  fileSystems."/primary/archive" = {
    device = "primary/archive";
    fsType = "zfs";
  };

  fileSystems."/primary/text" = {
    device = "primary/text";
    fsType = "zfs";
  };

  fileSystems."/secondary" = {
    device = "secondary";
    fsType = "zfs";
  };

  swapDevices =
    [{ device = "/dev/disk/by-uuid/51302f97-4b06-4bc1-8200-13217440af0f"; }];

  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";
  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;
}
