{ stdenv, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "modemmanager_exporter";
  version = "0.1.0";

  goPackagePath = "github.com/mdlayher/modemmanager_exporter";

  src = fetchFromGitHub {
    owner = "mdlayher";
    repo = "modemmanager_exporter";
    rev = "v${version}";
    sha256 = "0d8z7qzk5j5jj0ixkwpi8dw9kki78mxrajdlzzcj2rcgbnwair91";
  };

  modSha256 = "0vjnl6apihqb9vawspwvgqx3ckd0j66v10xc1cq6vf1nm07z76w8";

  meta = with stdenv.lib; {
    homepage = "github.com/mdlayher/modemmanager_exporter";
    description = "Prometheus exporter for ModemManager and its devices.";
    license = licenses.mit;
    maintainers = with maintainers; [ mdlayher ];
  };
}
