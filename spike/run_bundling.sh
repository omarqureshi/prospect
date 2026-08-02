#!/usr/bin/env bash
# Does `Runtime.RUBY_4_0.bundling_image` actually build native-extension gems,
# and can an x86_64 host produce arm64 artifacts? Logs to spike/logs/.
set -u
cd "$(dirname "$0")"
mkdir -p logs bundling-out-amd64 bundling-out-arm64

IMG=public.ecr.aws/sam/build-ruby4.0

for PLAT in amd64 arm64; do
  LOG="logs/${PLAT}.log"
  {
    echo "### platform=linux/${PLAT}"
    T0=$(date +%s)
    docker pull --platform "linux/${PLAT}" "$IMG" >/dev/null 2>&1
    echo "pull_seconds=$(( $(date +%s) - T0 ))"

    T1=$(date +%s)
    docker run --rm --platform "linux/${PLAT}" \
      -v "$PWD/bundling":/asset-input \
      -v "$PWD/bundling-out-${PLAT}":/asset-output \
      -w /asset-input \
      "$IMG" \
      bash -c '
        set -e
        ruby -v
        echo "host_arch=$(uname -m)"
        bundle config set --local path /asset-output/vendor/bundle
        bundle install
        cp -au . /asset-output
        echo "--- built extensions:"
        find /asset-output/vendor/bundle -name "*.so" | head -20
        echo "--- extension dirs:"
        ls /asset-output/vendor/bundle/ruby/*/extensions/ 2>/dev/null
      ' 2>&1
    echo "build_seconds=$(( $(date +%s) - T1 ))"
    echo "exit_status=$?"
  } > "$LOG" 2>&1
  echo "done ${PLAT}"
done
echo ALL_DONE
