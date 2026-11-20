# isa-scan PATH...: one TSV line per ELF file under PATH:
#   file  isa-needed-note  v3-instructions  instructions
# v3-instructions counts mnemonics that x86-64-v2 does not have (BMI1/2,
# LZCNT, MOVBE, FMA, AVX2 integer and gather forms; not TZCNT, which old CPUs
# run as BSF and baseline code therefore uses). Baseline builds contain
# some too (ifunc and target-attribute code paths), so compare a generic and
# a v3 build of the same package instead of reading one number alone.
v3='((shlx|shrx|sarx|rorx|mulx|andn|bextr|blsi|blsmsk|blsr|bzhi|pdep|pext|lzcnt|movbe)[bwlq]?|vfn?m(add|sub)(sub|add)?[0-9]{3}[ps][sd]|vpbroadcast[bwdq]|vperm2i128|vinserti128|vextracti128|vpgather[dq][dq]|vgather[dq]p[sd]|vpmaskmov[dq]|vpsllv[dq]|vpsrlv[dq]|vpsrav[d])'
find "$@" -type f -print0 | while IFS= read -r -d '' f; do
  [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
  note=$(readelf -n "$f" 2>/dev/null | awk -F': ' '/x86 ISA needed/ {print $2; exit}')
  counts=$(objdump -d --no-show-raw-insn "$f" 2>/dev/null \
    | awk -v re="^$v3\$" 'NF >= 2 && $1 ~ /:$/ { total++; if ($2 ~ re) n++ } END { printf "%d\t%d", n, total }')
  printf '%s\t%s\t%s\n' "$f" "${note:--}" "$counts"
done
