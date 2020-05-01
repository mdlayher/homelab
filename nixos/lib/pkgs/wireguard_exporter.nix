{ stdenv, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "wireguard_exporter";
  version = "0.1.2";

  goPackagePath = "github.com/mdlayher/wireguard_exporter";

  src = fetchFromGitHub {
    owner = "mdlayher";
    repo = "wireguard_exporter";
    rev = "v${version}";
    sha256 = "0mmrkdxh1q8n4zbj0gdx8qbrga78qg1zzyi71qk5ywl8vz0a05n0";
  };

  modSha256 = "065a8jnkjbs57fyr9493b2m66ajq4wr6hsbl54s9yw0gj6jpn5w4";

  meta = with stdenv.lib; {
    homepage = "github.com/mdlayher/wireguard_exporter";
    description = "Prometheus exporter for WireGuard devices.";
    license = licenses.mit;
    maintainers = with maintainers; [ mdlayher ];
  };
}
