{ stdenv, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "wireguard_exporter";
  version = "0.1.1";

  goPackagePath = "github.com/mdlayher/wireguard_exporter";

  src = fetchFromGitHub {
    owner = "mdlayher";
    repo = "wireguard_exporter";
    rev = "v${version}";
    sha256 = "06hh65c5qn7sbhcm23mgww44mc51kf37iv73hjxcmg4yac4fi65h";
  };

  modSha256 = "065a8jnkjbs57fyr9493b2m66ajq4wr6hsbl54s9yw0gj6jpn5w4";

  meta = with stdenv.lib; {
    homepage = "github.com/mdlayher/wireguard_exporter";
    description = "Prometheus exporter for WireGuard devices.";
    license = licenses.mit;
    maintainers = with maintainers; [ mdlayher ];
  };
}
