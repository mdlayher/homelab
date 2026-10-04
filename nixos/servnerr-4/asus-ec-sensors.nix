# The board's ASUS EC reports a CPU_Opt fan that the asus-ec-sensors
# driver leaves out of this board's sensor set. This builds the driver
# from the running kernel's own source with the upstream patch adding it
# (asus-ec-sensors-x570e-cpu-opt.patch, the commit as sent to
# linux-hwmon), and depmod prefers it over the in-tree module.
#
# The patch stops applying once the kernel already contains it, which
# fails the build: that is the signal to delete this file.
{ config, pkgs, ... }:

let
  kernel = config.boot.kernelPackages.kernel;

  asus-ec-sensors = pkgs.stdenv.mkDerivation {
    pname = "asus-ec-sensors-x570e-cpu-opt";
    version = kernel.modDirVersion;
    src = kernel.src;
    nativeBuildInputs = kernel.moduleBuildDependencies;

    unpackPhase = ''
      tar xf $src --wildcards '*/drivers/hwmon/asus-ec-sensors.c' --strip-components=1
    '';

    patches = [ ./asus-ec-sensors-x570e-cpu-opt.patch ];

    buildPhase = ''
      cd drivers/hwmon
      echo 'obj-m := asus-ec-sensors.o' > Makefile
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M=$PWD modules
    '';

    # Two modules share the name, and depmod picks between them by search
    # order; without a search line the choice falls to directory order.
    installPhase = ''
      install -D asus-ec-sensors.ko $out/lib/modules/${kernel.modDirVersion}/extra/asus-ec-sensors.ko
      mkdir -p $out/etc/depmod.d
      echo 'search extra built-in' > $out/etc/depmod.d/asus-ec-sensors.conf
    '';
  };
in
{
  boot.extraModulePackages = [ asus-ec-sensors ];
}
