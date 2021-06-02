{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "wireguard_exporter";
  version = "0.1.2";

  src = fetchFromGitHub {
    owner = "mdlayher";
    repo = "wireguard_exporter";
    rev = "v${version}";
    sha256 = "0mmrkdxh1q8n4zbj0gdx8qbrga78qg1zzyi71qk5ywl8vz0a05n0";
  };

  vendorSha256 = "18jqgjxrmvni1h69lzgnrwjl6b59xyn4qb4rfsd4kmpmg40g85yh";

  meta = with lib; {
    homepage = "github.com/mdlayher/wireguard_exporter";
    description = "Prometheus exporter for WireGuard devices.";
    license = licenses.mit;
    maintainers = with maintainers; [ mdlayher ];
  };
}
