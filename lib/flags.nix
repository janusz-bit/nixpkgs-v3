# CachyOS build flags of the x86-64-v3 repositories (cachyos-v3, cachyos-core-v3,
# cachyos-extra-v3), as data. Single source for the overlay and docs/status.md.
#
# Source: CachyOS/docker-makepkg, docker-makepkg-v3/makepkg.conf and rust.conf at
# 77856469646042cf11e1442a5cf73cc30a84082b (2024-11-02, the image the CachyOS
# build server uses for the v3 repositories). The user-side pacman makepkg.conf
# in CachyOS-PKGBUILDS uses -march=native and is not what the repositories are
# built with.
{
  march = "x86-64-v3";
  mtune = "generic";
  goamd64 = "v3";

  # Verbatim, for the status table. The overlay applies only part of them
  # globally; README.md ("Flag parity") says which and why.
  cflags = [
    "-march=x86-64-v3"
    "-mtune=generic"
    "-O3"
    "-pipe"
    "-fno-plt"
    "-fexceptions"
    "-Wp,-D_FORTIFY_SOURCE=3"
    "-Wformat"
    "-Werror=format-security"
    "-fstack-clash-protection"
    "-fcf-protection"
    "-mpclmul"
  ];
  cxxflagsExtra = [ "-Wp,-D_GLIBCXX_ASSERTIONS" ];
  ldflags = [
    "-Wl,-O1"
    "-Wl,--sort-common"
    "-Wl,--as-needed"
    "-Wl,-z,relro"
    "-Wl,-z,now"
    "-Wl,-z,pack-relative-relocs"
  ];
  ltoflags = [ "-flto=auto" ];
  rustflags = [
    "-C opt-level=3"
    "-C target-cpu=x86-64-v3"
    "-Clink-arg=-z"
    "-Clink-arg=pack-relative-relocs"
  ];
}
