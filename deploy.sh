#!/bin/bash

# shellcheck disable=SC2155

__command(){
  local title="$1"
  local silent="$2"  # 0 or 1
  shift;shift

  [[ "${__DEBUG}" -eq 1 ]] && echo "Command: $*"

  echo -n "${title}..."

  if [[ ${silent} -eq 1 ]]; then
    "$@" 1>/dev/null 2>&1
    local __ec=$?
    if [[ $__ec -eq 0 ]]; then
      echo "OK"
    else 
      echo "FAILED"
    fi
    return ${__ec}
  else
    "$@"
    return $?
  fi
}

install_script(){
    local answer=$1
    local _remote_ver=$(curl https://raw.githubusercontent.com/hapylestat/native_container_app/master/version 2>/dev/null)

    __command "Downloading stub script" 1 curl https://raw.githubusercontent.com/hapylestat/native_container_app/master/src/example.sh -o "${answer}.sh" 
    if [[ ! -f .config ]]; then
    __command "Downloading blank config" 1 curl https://raw.githubusercontent.com/hapylestat/native_container_app/master/src/.config -o .config
    fi
    __command "Downloading lib file" 1 curl https://raw.githubusercontent.com/hapylestat/native_container_app/master/src/container.lib.sh -o container.lib.sh 
    sed -i "s/LIB_VERSION=\"0.0.0\"/LIB_VERSION=\"${_remote_ver}\"/" "container.lib.sh"

    __command "Fixing permissions..." 1 chmod +x "${answer}.sh" 
    __command "Init..." 0 "${answer}.sh" init
}

install_script "$1"
