{ stdenv, buildGoModule, fetchFromGitHub, pkgs }:

buildGoModule rec {
  pname = "conprof";
  version = "3457edb30fc42eede8bc273537a4bfc94d766b8a";

  # Tests require graphviz, docker, and potentially a specific Go/Linux install?
  doCheck = false;

  # dot is required for rendering SVGs.
  nativeBuildInputs = [ pkgs.graphviz ];

  goPackagePath = "github.com/conprof/conprof";

  src = fetchFromGitHub {
    owner = "conprof";
    repo = "conprof";
    rev = "3457edb30fc42eede8bc273537a4bfc94d766b8a";
    sha256 = "1w60c88gzg92xpck6p23i9dndh8m05l316xafzv9g2wg7wd3jnhw";
  };

  vendorSha256 = "08il74ywi6llxsjbj5d036hs8ivjzx4x1mhlpv3a7x9fxsj67pxm";

  meta = with stdenv.lib; {
    homepage = "https://github.com/conprof/conprof";
    description = "Continuous profiling for pprof compatible profiles.";
    license = licenses.asl20;
    maintainers = with maintainers; [ mdlayher ];
  };
}
