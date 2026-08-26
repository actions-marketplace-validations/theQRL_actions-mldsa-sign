#!/bin/bash

set -e
set -o pipefail

/qrlft/qrlft sign -a mldsa --hexseed "$1" --context "$2" $4 > "$3"
