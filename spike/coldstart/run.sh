#!/usr/bin/env bash
# Runs bench.rb inside the real Lambda runtime image at CPU shares matching
# Lambda's memory->vCPU allocation (1769MB == 1 vCPU).
set -u
cd "$(dirname "$0")"

IMG=public.ecr.aws/lambda/ruby:4.0
REPS=${REPS:-7}
SCENARIOS="baseline json sorbet sorbet+structs sorbet+structs+validate sorbet+sigs sorbet+sigs+never full"

cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "sorbet-runtime"
gem "rack"
EOF

# Install gems once into a local path the container can see.
docker run --rm -v "$PWD":/w -w /w --entrypoint bash "$IMG" -c \
  'bundle config set --local path vendor/bundle >/dev/null && bundle install >/dev/null 2>&1 && echo installed' || exit 1

for mem in 512 1024 1769; do
  cpus=$(awk -v m="$mem" 'BEGIN{printf "%.2f", (m>1769?1:m/1769)}')
  echo "### memory=${mem}MB cpus=${cpus}"
  for s in $SCENARIOS; do
    times=$(docker run --rm --cpus "$cpus" -v "$PWD":/w -w /w --entrypoint bash "$IMG" -c \
      "for i in \$(seq 1 $REPS); do BUNDLE_GEMFILE=/w/Gemfile bundle exec ruby bench.rb $s 2>/dev/null; done" 2>/dev/null)
    med=$(echo "$times" | sort -n | awk '{a[NR]=$1} END{print (NR%2==1)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')
    printf "  %-28s %8s ms\n" "$s" "$med"
  done
done
echo ALL_DONE
