#!/bin/bash
set -e

cat <<'EOF'
platform-wip dev environment

  ./bld/build.sh      -> bin/platform
  ./bld/test.sh       -> unit + integration tests
  bin/platform init   -> create .store/ here to try the CLI

EOF

exec "${@:-bash}"
