{ ... }:

{
  nix = {
    # Automatic Nix GC.
    gc = {
      automatic = true;
      dates = "04:00";
      options = "--delete-older-than 30d";
    };
    extraOptions = ''
      min-free = ${toString (500 * 1024 * 1024)}
    '';

    # Automatic store optimization.
    autoOptimiseStore = true;
  };
}
