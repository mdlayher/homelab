{ stdenv, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "corerad";
  version = "0.1.5";

  goPackagePath = "github.com/mdlayher/corerad";

  src = fetchFromGitHub {
    owner = "mdlayher";
    repo = "corerad";
    rev = "v${version}";
    sha256 = "0id18w7bfqsn7jdminxsflxxpbq13921r017q8f82ppxaz37qlkr";
  };

  modSha256 = "1d6xcvzkrdcjwva2l34ipplqql19biq1b6wmj66pyy7d8dl3lgwa";

  meta = with stdenv.lib; {
    homepage = "https://github.com/mdlayher/corerad";
    description = "CoreRAD extensible and observable IPv6 NDP RA daemon";
    license = licenses.asl20;
    maintainers = with maintainers; [ mdlayher ];
  };
}
