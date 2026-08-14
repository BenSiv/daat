#!/bin/bash
set -e

cat <<'EOF'
daat dev environment

  ./bld/build.sh      -> bin/daat
  ./bld/test.sh       -> unit + integration tests
  bin/daat init       -> create .store/ here to try the CLI

EOF

exec "${@:-bash}"
