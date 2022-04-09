#!/bin/bash


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

read -rep "Application name: " -i "example" answer



__command "Downloading stub script" 1 curl https://raw.githubusercontent.com/hapylestat/native_container_app/master/src/container.lib.sh -o "${answer}.sh" 
__command "Downloading lib file" 1 curl https://raw.githubusercontent.com/hapylestat/native_container_app/master/src/container.lib.sh -o container.lib.sh 
__command "Fixing permissions..." 1 chmod +x "${answer}.sh" 
__command "Initializing..." 0 "${answer}.sh" download