#!/bin/bash

# shellcheck disable=SC2155,SC1091,SC2015

__dir(){
 local SOURCE="${BASH_SOURCE[0]}"
 while [[ -h "$SOURCE" ]]; do
   local DIR=$(cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd)
   local SOURCE="$(readlink "$SOURCE")"
   [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
 done
 echo -n $(cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd)
}

DIR=$(__dir)

. "${DIR}/container.lib.sh"