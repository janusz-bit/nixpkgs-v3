# Proof that the v3 world is v3 and what it buys, generic against v3 for the
# same nixpkgs revision and the same packages the laptop uses:
#   isa-proof  scans ELF files of both builds (isa-scan) and fails unless every
#              v3 file carries clearly more v3-only instructions than its
#              generic twin, or a GNU ISA note naming x86-64-v3;
#   bench      hyperfine A/B of zstd, xz, python3 and ffmpeg on the runner.
# Both need the v3 packages in the cache; workflow proof.yml checks that with
# a dry run first instead of building the world here.
{
  lib,
  generic,
  v3,
  isa-scan,
}:
let
  # attribute -> files to scan, relative to the package outputs.
  samples = {
    zstd = [ "bin/zstd" ];
    xz = [ "bin/xz" ];
    python3 = [ "bin/python3" ];
    glibc = [ "lib/libc.so.6" ];
    fish = [ "bin/fish" ];
    tailscale = [ "bin/tailscaled" ];
  };

  scanList =
    set:
    lib.concatStringsSep " " (
      lib.flatten (lib.mapAttrsToList (attr: files: map (f: "${attr}=${set.${attr}}/${f}") files) samples)
    );
in
{
  isa-proof = generic.runCommand "nixpkgs-v3-isa-proof" { nativeBuildInputs = [ isa-scan ]; } ''
    scan() {
      for pair in $1; do
        attr=''${pair%%=*}; file=''${pair#*=}
        printf '%s\t' "$attr"; isa-scan "$(readlink -f "$file")"
      done
    }
    scan ${lib.escapeShellArg (scanList generic)} > generic.tsv
    scan ${lib.escapeShellArg (scanList v3)} > v3.tsv
    mkdir -p $out
    {
      printf '| package | generic v3-insns/insns | v3 v3-insns/insns | v3 ISA note |\n|---|---|---|---|\n'
      paste generic.tsv v3.tsv | awk -F'\t' '{ printf "| %s | %d/%d | %d/%d | %s |\n", $1, $4, $5, $9, $10, $8 }'
    } | tee $out/isa.md
    paste generic.tsv v3.tsv | awk -F'\t' '
      { ok = ($8 ~ /x86-64-v3/) || ($9 > 2 * $4 + 50); if (!ok) { print "not v3: " $1; bad = 1 } }
      END { exit bad }'
  '';

  bench = generic.writeShellApplication {
    name = "nixpkgs-v3-bench";
    runtimeInputs = [
      generic.hyperfine
      generic.gnutar
      generic.coreutils
    ];
    text = ''
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      tar -cf "$work/corpus.tar" -C ${generic.python3} lib
      head -c 64M "$work/corpus.tar" > "$work/corpus64"
      ${generic.zstd}/bin/zstd -q -19 -T1 "$work/corpus64" -o "$work/c.zst"
      ${generic.xz}/bin/xz -k -6 -T1 -c "$work/corpus64" > "$work/c.xz"
      cp ${./bench.py} "$work/bench.py"
      cd "$work"
      run() { hyperfine --style basic --warmup 1 --runs "$1" --export-markdown "$2.md" -n generic "$3" -n v3 "$4"; cat "$2.md"; }
      run 5 zstd-19 "${generic.zstd}/bin/zstd -q -19 -T1 -f corpus64 -o /dev/null" "${v3.zstd}/bin/zstd -q -19 -T1 -f corpus64 -o /dev/null"
      run 10 zstd-d "${generic.zstd}/bin/zstd -q -d -c c.zst" "${v3.zstd}/bin/zstd -q -d -c c.zst"
      run 3 xz-6 "${generic.xz}/bin/xz -6 -T1 -c corpus64" "${v3.xz}/bin/xz -6 -T1 -c corpus64"
      run 10 xz-d "${generic.xz}/bin/xz -d -c c.xz" "${v3.xz}/bin/xz -d -c c.xz"
      run 5 python3 "${generic.python3}/bin/python3 bench.py" "${v3.python3}/bin/python3 bench.py"
      run 3 ffmpeg "${generic.ffmpeg-headless}/bin/ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 10 -vf scale=1920:1080:flags=lanczos -c:v mpeg4 -f null -" "${v3.ffmpeg-headless}/bin/ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 10 -vf scale=1920:1080:flags=lanczos -c:v mpeg4 -f null -"
    '';
  };
}
