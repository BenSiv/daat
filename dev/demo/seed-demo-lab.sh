#!/bin/sh
set -eu

# First-boot seed for the demo deployment: builds the demo lab
# (tst/eval/demo-lab, doc/agent-eval.md) into /data, the same way
# bld/eval-env.sh builds it into a temp folder. Expects /data to hold
# platform.lua already and no store yet.
#
#   seed-demo-lab.sh [seed]

cd /data
rm -rf schemas
cp -r /app/tst/eval/demo-lab/schemas schemas

# The loader embeds every document right after creating it and refuses
# a lab with any left unembedded, so the seed runs with no embedding
# quiet period; the deployment's own platform.lua is restored after.
cp platform.lua platform.lua.deployed
trap 'mv platform.lua.deployed platform.lua' EXIT
sed 's/^return {/return {embedding_quiet_minutes = 0,/' platform.lua.deployed > platform.lua

export LUA_PATH="/app/src/?.lua;/luam/lib/?.lua;/luam/lib/?/init.lua;;"
export LUA_CPATH="/luam/bin/?.so;/luam/lib/lfs/?.so;/luam/lib/hmac/?.so;/luam/lib/bcrypt/?.so;/luam/lib/mariadb/?.so;;"
/luam/bin/luam /app/tst/eval/load.lua /app "${1:-20261020}"

# The loader's own account has a fixed password, published in
# tst/eval/load.lua. Its records stay attributed to it; it just can't
# log in on a public deployment.
/app/bin/daat user archive eval
