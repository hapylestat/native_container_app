#!/bin/bash

# The script is provided as-is with no responsibility
#
# The current LICENSE header should be preserved in
# all future copies of the script including original
# author and mail.
# 
# Author: simca
# Mail  : me at nxa dot io

# shellcheck disable=SC2155,SC1091,SC2015

LIB_VERSION="0.0.0"
PATH=${PATH}:/usr/bin
__DEBUG=0

__dir(){
 local SOURCE="${BASH_SOURCE[0]}"
 while [[ -h "$SOURCE" ]]; do
   local DIR=$(cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd)
   local SOURCE="$(readlink "$SOURCE")"
   [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
 done
 # shellcheck disable=SC2046
 echo -n $(cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd)
}

DIR=$(__dir)

declare -A _COLOR=(
  [INFO]="\033[38;05;39m"
  [ERROR]="\033[38;05;161m"
  [WARN]="\033[38;05;178m"
  [OK]="\033[38;05;40m"
  [GRAY]="\033[38;05;245m"
  [RESET]="\033[m"
)


__command(){
  local title="$1"
  local status="$2"  # 0 or 1
  shift;shift

  [[ "${__DEBUG}" -eq 1 ]] && echo "${_COLOR[INFO]}[CMD-DBG] ${_COLOR[GRAY]} $* ${_COLOR[RESET]}"

  if [[ ${status} -eq 1 ]]; then
    echo -n "${title}..."
    "$@" 1>/dev/null 2>&1
    local n=$?
    [[ $n -eq 0 ]] && echo -e "${_COLOR[OK]}ok${_COLOR[RESET]}" || echo -e "${_COLOR[ERROR]}fail[#${n}]${_COLOR[RESET]}"
    return ${n}
  else
   echo "${title}..."
    "$@"
    return $?
  fi
}

__run(){
 echo -ne "${_COLOR[INFO]}[EXEC] ${_COLOR[GRAY]}$* -> ["
 "$@" 1>/dev/null 2>/dev/null
 local n=$?
 [[ $n -eq 0 ]] && echo -e "${_COLOR[OK]}ok${_COLOR[GRAY]}]${_COLOR[RESET]}" || echo -e "${_COLOR[ERROR]}fail[#${n}]${_COLOR[GRAY]}]${_COLOR[RESET]}"
 return ${n}
}

__echo() {
 local _lvl="INFO"
 [[ "${1^^}" == "INFO" ]] || [[ "${1^^}" == "ERROR" ]] || [[ "${1^^}" == "WARN" ]] && { local _lvl=${1^^}; shift; }
 
 echo -e "${_COLOR[${_lvl}]}[${_lvl}]${_COLOR[RESET]} $*"
}

# Include configuration files
[[ -f "${DIR}/.secrets" ]] && { . "${DIR}/.secrets"; __echo "Including secrets..."; }
. "${DIR}/.config"


APPLICATION=${APPLICATION:-}
VER=${VER:-}
VOLUMES=${VOLUMES:-}           
ENVIRONMENT=${ENVIRONMENT:-}   
CMD=${CMD:-}                   
IP=${IP:-}
ATTACH_NVIDIA=${ATTACH_NVIDIA:-0}
CONTAINER_CAPS=${CONTAINER_CAPS:-}
CAPS_PRIVILEGED=${CAPS_PRIVILEGED:0}
BUILD_ARGS=${BUILD_ARGS:-}

NS_USER=${NS_USER:-containers}
declare -A LIMITS=${LIMITS:([CPU]="0.0" [MEMORY]=0)}
declare -A CUSTOM_COMMANDS=${CUSTOM_COMMANDS:()}; unset "CUSTOM_COMMANDS[0]"
declare -A CUSTOM_FLAGS=${CUSTOM_FLAGS:()}; unset "CUSTOM_FLAGS[0]"


IS_LXCFS_ENABLED=$([[ -d "/var/lib/lxcfs" ]] && echo "1" || echo "0")
# options required if LXCFS is installed
LXC_FS_OPTS=(
  "-v" "/var/lib/lxcfs/proc/cpuinfo:/proc/cpuinfo:rw"
  "-v" "/var/lib/lxcfs/proc/diskstats:/proc/diskstats:rw"
  "-v" "/var/lib/lxcfs/proc/meminfo:/proc/meminfo:rw"
  "-v" "/var/lib/lxcfs/proc/stat:/proc/stat:rw"
  "-v" "/var/lib/lxcfs/proc/swaps:/proc/swaps:rw"
  "-v" "/var/lib/lxcfs/proc/uptime:/proc/uptime:rw"
)

CONTAINER_BIN="podman"


verify_requested_resources(){
  local system_cpu_cores=$(nproc)
  local total_system_memory=$(grep MemTotal /proc/meminfo|awk '{print $2}')
  local total_system_memory=$((total_system_memory / 1024 / 1024))
  local is_error=0

  if [[ "${LIMITS[MEMORY]%.*}" -gt "${total_system_memory%.*}" ]]; then
    local is_error=1
    __echo error "Available system memory: ${total_system_memory%.*} GB, but requested ${LIMITS[MEMORY]%.*} GB"
  fi

  if [[ "${LIMITS[CPU]%.*}" -gt "${system_cpu_cores%.*}" ]]; then 
    local is_error=1
    __echo error "Available system cpu cores: ${system_cpu_cores}, but requested ${LIMITS[CPU]}"
  fi

  [[ ${is_error} -eq 1 ]] && exit 1
}

_add_nvidia_mounts(){
  if [[ ! -f /usr/bin/nvidia-container-cli ]]; then 
    echo "Please install libnvidia-container tools: "
    echo "   - https://github.com/NVIDIA/libnvidia-container"
    echo "   - https://nvidia.github.io/libnvidia-container/"
    exit 1
  fi
  local _args="--cap-add=ALL" # required 
  local _driver_version=$(nvidia-container-cli info|grep "NVRM"|awk -F ':' '{print $2}'|tr -d ' ')

  for _dev in /dev/nvidia*; do 
    local _args="${_args} --device ${_dev}"
  done 
  
  for item in $(nvidia-container-cli list|grep -v "dev"); do 
    if [[ ${item} == *".so"* ]]; then
      local _path_nover=${item%".${_driver_version}"}
      local _args="${_args} -v ${item}:${item}:ro -v ${item}:${_path_nover}:ro -v ${item}:${_path_nover}.1:ro"
    else 
      local _args="${_args} -v ${item}:${item}:ro"
    fi
  done

  [[ -d /dev/dri ]] &&  local _args="${_args} -v /dev/dri:/dev/dri" || true

  echo -n "${_args}"
}

_nvidia_cuda_init(){
  # https://askubuntu.com/questions/590319/how-do-i-enable-automatically-nvidia-uvm
  # https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#runfile-verifications

  if /sbin/modprobe nvidia; then
    # Count the number of NVIDIA controllers found.
    NVDEVS=$(lspci | grep -i NVIDIA)
    N3D=$(echo "$NVDEVS" | grep -c "3D controller")
    NVGA=$(echo "$NVDEVS" | grep -c "VGA compatible controller")

    N=$((N3D + NVGA - 1))
    for i in $(seq 0 $N); do
      mknod -m 666 "/dev/nvidia$i" c 195 "$i" 1>/dev/null 2>&1
    done

    mknod -m 666 /dev/nvidiactl c 195 255 1>/dev/null 2>&1
  else
    return 1
  fi

  if /sbin/modprobe nvidia-uvm; then
    # Find out the major device number used by the nvidia-uvm driver
    D=$(grep nvidia-uvm /proc/devices | awk '{print $1}')

    mknod -m 666 /dev/nvidia-uvm c "${D}" 0 1>/dev/null 2>&1
  else
    return 1
  fi
  return 0
}

do_start() {
 local -n flags=$1
 local ver=${FLAGS[VER]}
 local clean=${FLAGS[CLEAN]}
 local attach=${FLAGS[ATTACH]}
 local interactive=${FLAGS[INTERACTIVE]}
 local volumes=""
 local envi=""
 local lxcfs_mounts=""
 local limits_mem=""
 local limits_cpu=""
 local nvidia_args=""
 local caps=""

 [[ ${clean} -eq 1 ]] && [[ ${attach} -eq 1 ]] && { echo "[E] -c and -a options cannot be used together!"; return; }

 [[ ATTACH_NVIDIA -eq 1 ]] && { __command "[i] Initializing CUDA" 1 _nvidia_cuda_init; local nvidia_args=$(_add_nvidia_mounts); echo "[i] Attaching NVIDIA stuff to container..."; } || echo -n

 verify_requested_resources
 if [[ ${LIMITS[CPU]%.*} -ne 0 ]]; then 
  local total_cores=$(($(nproc) - 1))
  local min_core=$((total_cores - LIMITS[CPU] - 1))
  local limits_cpu="--cpuset-cpus=${min_core}-${total_cores}"; echo -e "CPU cores set:\n- ${min_core}-${total_cores}"
 fi

 if [[ ${LIMITS[CPU]%.*} -ne 0 ]]; then 
  echo -e "MEMORY limits:\n- ${LIMITS[MEMORY]}"
  local limits_mem="--memory=${LIMITS[MEMORY]}G"
 fi

 echo "LXS-FS extension is installed: "
 [[ "${IS_LXCFS_ENABLED}" -eq 1 ]] && { local lxcfs_mounts=${LXC_FS_OPTS[*]}; echo "- YES"; } || { echo "- NO"; }

 echo "Container volumes:"
 for v in "${VOLUMES[@]}"; do
   # shellcheck disable=SC2206
   local share=(${v//:/ })
   [[ "${share[0]}" == "" ]] && { echo " - no volumes"; continue; }
   [[ "${share[0]:0:1}" == "/" ]] && { local _src_dir=${share[0]}; } || { local _src_dir="${DIR}/storage/${share[0]}"; }

   [[ ! -d "${_src_dir}" ]] && mkdir -p "${_src_dir}" 1>/dev/null 2>&1

   local volumes="${volumes}-v ${_src_dir}:${share[1]} "; echo " - ${_src_dir} => ${share[1]}"
 done
 
 echo "Environment variables:"
 for v in "${ENVIRONMENT[@]}"; do
   # shellcheck disable=SC2206
   local _env=(${v//=/ })
   [[ "${_env[0]}" == "" ]] && { echo " - no variables"; continue; }
   local envi="${envi}-e ${_env[0]}=${_env[1]} "; echo " - ${_env[0]} = ${_env[1]}"
 done

 echo "Container CAPS:"
 if [[ ${CAPS_PRIVILEGED} -eq 0 ]]; then
  for v in "${CONTAINER_CAPS[@]}"; do
    [[ "${v}" == "" ]] && { echo " - no CAPS"; continue; }
    local caps="${caps}--cap-add ${v} "; echo " - ${v}"
  done
 else 
  local caps="--privileged";  echo " - privileged mode"
 fi

 # network 
 [[ "${IP}" == "host" ]] && { local _net_argument="--net=host"; } || { local _net_argument="--ip=${IP}"; }

 # NS Isolation
 echo -n "NS_USER mapping: "
 if [[ "${NS_USER}" == "keep-id" ]]; then
   local __ns_arguments="";  echo "none"
 elif [[ "${NS_USER:0:1}" == "@" ]]; then 
   local __ns_arguments="--user=${NS_USER:1}";  echo "run as user"
 else
   local __ns_arguments="--subuidname=${NS_USER} --subgidname=${NS_USER}"; echo "uid and gid mapping"
 fi

 echo -e "Container IP:\n - ${IP}"

 local action="start"

 if ${CONTAINER_BIN} container exists "${APPLICATION}" 1>/dev/null 2>&1; then
   __command "Stopping container" 1 ${CONTAINER_BIN} stop -i -t 5 "${APPLICATION}"
  [[ ${clean} -eq 1 ]] && { __command "[!] Removing already existing container..." 1 ${CONTAINER_BIN} rm -fiv "${APPLICATION}"; local action="run"; }
 else
   local action="run"
 fi

 if [[ "${action}" == "start" ]]; then  
   [[ ${attach} -eq 1 ]] && local option="-a"  || local option=""
   [[ ${attach} == 0 ]] && local _silent=1 || local _silent=0 # flip attach value and store to _silent
   __command "[!] Starting container..." ${_silent} ${CONTAINER_BIN} start "${option}" "${APPLICATION}"
 else 
   [[ ${interactive} -eq 1 ]] && { local action="run"; local options="-it --entrypoint=bash"; echo "[i] Interactive run..."; } || { local action="run"; local options="-d"; }
   [[ ${attach} -eq 1 ]] && { local action="create"; local options=""; }

   # shellcheck disable=SC2086
  __command "[!] Creating and starting container..." 0 \
  ${CONTAINER_BIN} ${action} ${limits_cpu} ${limits_mem}\
  ${__ns_arguments}\
  --name ${APPLICATION}\
  --hostname ${APPLICATION}\
  ${caps}\
  ${options}\
  ${_net_argument}\
  ${lxcfs_mounts}\
  ${envi}\
  ${volumes}\
  ${nvidia_args}\
  localhost/${APPLICATION}:${ver}


  [[ ${attach} -eq 1 ]] && ${CONTAINER_BIN} start -a "${APPLICATION}"
 fi
}

do_stop() {
  local -n flags=$1
  local clean=${flags[CLEAN]}
  __command "[I] Stopping container ..." 1 ${CONTAINER_BIN} stop -t 10 "${APPLICATION}"
  [[ ${clean} -eq 1 ]] && __command "[!] Removing container..." 1 ${CONTAINER_BIN} rm "${APPLICATION}"
}

do_logs() {
 ${CONTAINER_BIN} logs "${APPLICATION}"
}

do_ssh() {
  ${CONTAINER_BIN} exec -it "${APPLICATION}" bash 2>/dev/null

  if [[ $? -ne 0 ]]; then
    ${CONTAINER_BIN} exec -it "${APPLICATION}" sh 
  fi
}

do_build() {
  local -n flags=$1
  local ver=${flags[VER]}
  local _clean_flag=${flags[CLEAN]}
  local _build_args=""

  if [[ ${_clean_flag} -eq 1 ]]; then
    local _build_args+="--rm --force-rm "
    if ${CONTAINER_BIN} image exists "localhost/${APPLICATION}:${ver}"; then
      __command "Removing already existing \"localhost/${APPLICATION}:${ver}\" ..." 1 ${CONTAINER_BIN} rmi -if "localhost/${APPLICATION}:${ver}"
    fi
  fi

  echo "Build args:"
  for v in "${BUILD_ARGS[@]}"; do
    # shellcheck disable=SC2206
    local _args=(${v//=/ })
    if [[ "${_args[0]}" == "" ]]; then
      echo " - no build args"
      continue
    fi
    local _build_args="${_build_args}--build-arg ${_args[0]}=${_args[1]} "
    echo " - ${_args[0]} = ${_args[1]}"
  done
  
  # shellcheck disable=SC2086
  ${CONTAINER_BIN} build --build-arg APP_VER="${VER}" ${_build_args} -t "localhost/${APPLICATION}:${ver}" container
}

do_init(){
 local dirs=("container" "storage")
 local docker_mkdir=""
 local docker_volumes=""
 local volumes=""
 for v in "${VOLUMES[@]}"; do
   [[ "${v}" == "" ]] && continue
   # shellcheck disable=SC2206
   local share=(${v//:/ })

   local docker_mkdir="${docker_mkdir}RUN mkdir -p ${share[1]}\n"
   local docker_volumes="${docker_volumes}VOLUME ${share[1]}\n"
   [[ "${share[0]:0:1}" != "/" ]] && local volumes+=("${share[0]}")
 done

 echo "Initializing folders structures..."
 for d in "${dirs[@]}"; do
    [[ ! -d "${DIR}/${d}" ]] && echo " - Creating ../${d}" || echo " - Skipping ../${d}"
 done

 if [[ -f "${DIR}/container/Dockerfile" ]]; then
   echo "Skipping ../container/Dockerfile creation..."
 else
   echo "Creating blank ../container/Dockerfile..."
   [[ ! -d "${DIR}/container" ]] && mkdir -p "${DIR}/container" || echo
  
   cat > "${DIR}/container/Dockerfile" <<EOF
FROM fedora:latest

ARG APP_VER
ENV APP_VER=\${APP_VER:-}

RUN dnf install -y curl &&\\
#    ....packages to install here.......
    dnf clean all
EOF

 echo -e "${docker_mkdir}" >> "${DIR}/container/Dockerfile"
 echo -e "${docker_volumes}" >> "${DIR}/container/Dockerfile" 

 if [[ ${ATTACH_NVIDIA} -eq 1 ]]; then
  # shellcheck disable=SC2028
  echo "RUN echo -e \"\\n\\n#Required for NVidia integration\\nldconfig\\n\" >> /root/.bashrc" >> "${DIR}/container/Dockerfile"
 fi

 echo "CMD [${CMD}]" >> "${DIR}/container/Dockerfile"
 fi
 
 echo "Create volumes..."
 local _change_owner=0
 if [[ "${NS_USER}" != "keep-id" ]] && [[ "${NS_USER:0:1}" != "@" ]]; then
   local _change_owner=1 
   local _uid=$(grep "${NS_USER}" /etc/subuid|cut -d ':' -f 2)
   local _gid=$(grep "${NS_USER}" /etc/subgid|cut -d ':' -f 2)
 fi

 # shellcheck disable=SC2048
 for v in ${volumes[*]}; do
  [[ "${v}" == "" ]] && continue
  local _dir="storage/${v}"

  echo -n " - mkdir ${_dir} ..."
  if [[ -d "${DIR}/${_dir}" ]]; then
    echo "exist"
  else 
   mkdir -p "${DIR}/${_dir}" 1>/dev/null 2>&1 && echo "created" || echo "failed"
  fi

  if [[ ${_change_owner} -eq 1 ]]; then
    echo " - permissions ${_dir} => ${_uid}:${_gid}, mode 700..."
    chown "${_uid}":"${_gid}" "${DIR}/${_dir}"
    chmod 700 "${DIR}/${_dir}"
  fi
 done
 

 echo -n "Creating systemd service file..."
 local service_name=$(basename "$0")
 # shellcheck disable=SC2206
 local service_name=(${service_name//./ })
 # shellcheck disable=SC2178
 local service_name=${service_name[0]}
 
 # shellcheck disable=SC2128
 
 if [[ ! -f "${DIR}/${service_name}.service" ]]; then
 cat > "${DIR}/${service_name}.service" <<EOF
[Unit]
Description=Podman ${service_name}.service
Wants=network.target
After=network-online.target

[Service]
Type=simple
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=on-failure
TimeoutStopSec=70
ExecStart=${DIR}/${service_name}.sh start -a
ExecStop=${DIR}/${service_name}.sh stop


[Install]
WantedBy=multi-user.target default.target
EOF
 echo "ok"
else
 echo "skipped"
fi
}


# https://stackoverflow.com/questions/4023830/how-to-compare-two-strings-in-dot-separated-version-format-in-bash
# Results: 
#          0 => =
#          1 => >
#          2 => <
__vercomp () {
    [[ "$1" == "$2" ]] && return 0 ; local IFS=. ; local i ver1=($1) ver2=($2)
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++));  do ver1[i]=0;  done
    for ((i=0; i<${#ver1[@]}; i++)); do
        [[ -z ${ver2[i]} ]] && ver2[i]=0
        ((10#${ver1[i]} > 10#${ver2[i]})) &&  return 1
        ((10#${ver1[i]} < 10#${ver2[i]})) &&  return 2
    done
    return 0
}

declare -A _COLOR=(
  [INFO]="\033[38;05;39m"
  [ERROR]="\033[38;05;161m"
  [WARN]="\033[38;05;178m"
  [OK]="\033[38;05;40m"
  [GRAY]="\033[38;05;245m"
  [RESET]="\033[m"
)

__ask() {
    local _title="${1}"
    read -rep "${1} (y/N): " answer < /dev/tty
    if [[ "${answer}" != "y" ]]; then
      __echo "error" "Action cancelled by the user"
      return 1
    fi
    return 0
}


handle_file(){
  IFS=" "
  local _name=${1}
  local _diff_line=${2}
  local _command=${_diff_line:0:1}
  local _file=${_diff_line:2}; local _file=${_file//..};local _file=${_file//\/}  # to avoid paths like ../../.something
  local _lib_download_uri="https://raw.githubusercontent.com/FluffyContainers/native_containers/master"
  local _lib_source_loc="src"

  case ${_command} in 
  -)
   [[ ! -f "${DIR}/${_file}" ]] &&  __echo "INFO" "Skipping ${_file} removal as file doesn't exists"  || __run rm -f "${DIR}/${_file}";;
  +)
    local _http_code=$(curl -s "${_lib_download_uri}/${_lib_source_loc}/${_file}" -o "${DIR}/${_file}" --write-out "%{http_code}")
    if [[ ${_http_code} -lt 200 ]] || [[ ${_http_code} -gt 299 ]]; then 
      __echo "error" "Failed to download file \"${_file}\": HTTP ${_http_code}"
    else 
      __echo "info" "Downloaded \"${_file}\" ... OK"
    fi
    ;;
  ?)
    if [[ -f "${DIR}/${_file}" ]] && [[ "${_file}" != "example.sh" ]]; then
      __echo "info" "Skipping download of optional \"${_file}\", as file already exists"
      return
    else  
      local _http_code=$(curl -s "${_lib_download_uri}/${_lib_source_loc}/${_file}" -o "${DIR}/${_file}" --write-out "%{http_code}")
      [[ ${_http_code} -lt 200 ]] || [[ ${_http_code} -gt 299 ]] && __echo "error" "Failed to download file \"${_file}\": HTTP ${_http_code}" || {
         [[ "${_file}" == "example.sh" ]] && {
          __run rm -f "${DIR}/${_name}.sh"
          __run mv "${DIR}/${_file}" "${DIR}/${_name}.sh"
          __run chmod +x "${DIR}/${_name}.sh" 
         }
        __echo "info" "Downloaded \"${_file}\" ... OK"
      }
    fi
    ;;
  *)
    __echo "ERROR" "Unknown instruction \"${_command}\"";;
  esac
}

__do_lib_upgrade() {
    local _lib_download_uri="https://raw.githubusercontent.com/FluffyContainers/native_containers/master"
    local _lib_source_loc="src"
    local _remote_ver=""
    
    echo -en "You're about to use remote lib source \"${_COLOR[ERROR]}${_lib_download_uri}${_COLOR[RESET]}\". "
    ! __ask "Agree to continue" && return 1

    local _remote_ver=$(curl "${_lib_download_uri}/version" 2>/dev/null)
    [[ -z ${_remote_ver} ]] && { __echo "error" "Can't retrieve remote version"; exit 1; }
    if ! __vercomp "${LIB_VERSION}" "${_remote_ver}"; then
        echo "Current version ${LIB_VERSION} are installed, while ${_remote_ver} are available ..."
        ! curl --output /dev/null --silent --head --fail "${_lib_download_uri}/download.diff" && { __echo "error" "Lib update list is not available at \"${_lib_download_uri}/download.diff\""; exit 1; }        

        local oldIFS="${IFS}"
        IFS=$'\n'; for line in $(curl -s ${_lib_download_uri}/download.diff); do 
            [[ "${line:0:1}" == "#" ]] && continue
            handle_file "${APP_NAME}" "${line}"
        done
        IFS=${oldIFS}
        if [[ -f "${DIR}/.container.lib.sh" ]]; then
            sed -i "s/LIB_VERSION=\"0.0.0\"/LIB_VERSION=\"${_remote_ver}\"/" "${DIR}/.container.lib.sh"
        fi

        __echo "Upgrade done, please referer to ${_lib_download_uri}/src/.config for new available conf options"
    else 
        __echo "Lib is already up to date"
    fi
}


upgrade_lib(){
  __do_lib_upgrade
}

show_help(){
  local -n commands=$1
  local -n flags=$2

  echo -e "\n${APPLICATION} v${VER} [wrapper v${LIB_VERSION}] help"
  echo -e "===============================================\n"

  echo "Available commands:"
  for c in ${!commands[*]}; do
    [[ "${c##*,}" == "F" ]] && continue
    echo "  - ${c%,*}"
  done

  echo -e "\nAvailable arguments:"
  for c in ${!flags[*]}; do
    [[ "${c:0:1}" == "-" ]] && continue
    echo "  - ${c}"
  done

}

#=============================================
declare -A COMMANDS=(
 [INIT,S]=0   [INIT,F]="do_init"
 [BUILD,S]=0  [BUILD,F]="do_build"
 [START,S]=0  [START,F]="do_start"
 [STOP,S]=0   [STOP,F]="do_stop"
 [LOGS,S]=0   [LOGS,F]="do_logs"
 [SSH,S]=0    [SSH,F]="do_ssh"
 [UPDATE,S]=0 [UPDATE,F]="upgrade_lib"
)

declare -A FLAGS=(
 [CLEAN]=0       [-C]=CLEAN         [--CLEAN]=CLEAN
 [ATTACH]=0      [-A]=ATTACH        [--ATTACH]=ATTACH
 [INTERACTIVE]=0 [-IT]=INTERACTIVE  [--INTERACTIVE]=INTERACTIVE
 [VER]=${VER} 
)

# Disallow internal commands override
for key in ${!CUSTOM_COMMANDS[*]}; do
  [[ ! ${COMMANDS[${key},F]+_} ]] && { COMMANDS[${key},S]=0; COMMANDS[${key},F]=${CUSTOM_COMMANDS[${key}]}; }
done

for key in ${!CUSTOM_FLAGS[*]}; do
  [[ ! ${FLAGS[${key^^}]+_} ]] && FLAGS[${key^^}]=${CUSTOM_FLAGS[${key^^}]}
done

for i in "${@}"; do
  if [[ ${COMMANDS[${i^^},S]+_} ]]; then
   COMMANDS[${i^^},S]=1
  elif [[ ${FLAGS[${i^^}]+_} ]]; then 
    FLAGS[${FLAGS[${i^^}]}]=1
  else case ${i,,} in
  -v=*|--ver=*)
    FLAGS[VER]="${i#*=}";;
  help|-h|--help)
    show_help COMMANDS FLAGS
    exit 0;;
 esac fi
 shift
done

for i in ${!COMMANDS[*]}; do 
  [[ "${i##*,}" == "F" ]] && continue
  [[ ${COMMANDS[${i%,*},S]} -eq 1 ]] && { ${COMMANDS[${i%,*},F]} FLAGS; exit $?; }
done

show_help COMMANDS FLAGS