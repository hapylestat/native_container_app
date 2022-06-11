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


__command(){
  local _c_tag="\033[38;05;39m"
  local _c_cmd="\033[38;05;245m"
  local _c_ok="\033[38;05;40m"
  local _c_fail="\033[38;05;161m"

  local title="$1"
  local silent="$2"  # 0 or 1
  shift;shift

  [[ "${__DEBUG}" -eq 1 ]] && echo "Command: $*"

  echo -n "${title}..."

  if [[ ${silent} -eq 1 ]]; then
    "$@" 1>/dev/null 2>&1
    local n=$?
    [[ $n -eq 0 ]] && echo -e "${_c_ok}ok\033[m" || echo -e "${_c_fail}fail[#${n}]\033[m"
    return ${n}
  else
    "$@"
    return $?
  fi
}

__run(){
 local _c_tag="\033[38;05;39m"
 local _c_cmd="\033[38;05;245m"
 local _c_ok="\033[38;05;40m"
 local _c_fail="\033[38;05;161m"

 echo -ne "${_c_tag}[EXEC] ${_c_cmd}$* -> ["
 "$@" 1>/dev/null 2>/dev/null
 local n=$?
 [[ $n -eq 0 ]] && echo -ne "${_c_ok}ok" || echo -ne "${_c_fail}fail[#${n}]"
 echo -e "${_c_cmd}]\033[m"
 return ${n}
}

__echo() {
 local _c_tag="\033[38;05;39m"
 echo -e "${_c_tag}[INFO] $*"
}


verify_requested_resources(){
  local system_cpu_cores=$(nproc)
  local total_system_memory=$(grep MemTotal /proc/meminfo|awk '{print $2}')
  local total_system_memory=$((total_system_memory / 1024 / 1024))
  local is_error=0

  if [[ "${LIMITS[MEMORY]%.*}" -gt "${total_system_memory%.*}" ]]; then
    local is_error=1
    echo "[ERROR] Available system memory: ${total_system_memory%.*} GB, but requested ${LIMITS[MEMORY]%.*} GB"
  fi

  if [[ "${LIMITS[CPU]%.*}" -gt "${system_cpu_cores%.*}" ]]; then 
    local is_error=1
    echo "[ERROR] Available system cpu cores: ${system_cpu_cores}, but requested ${LIMITS[CPU]}"
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

  echo -n "[i] Initializing CUDA ... "

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
    echo "fail"
    return 1
  fi

  if /sbin/modprobe nvidia-uvm; then
    # Find out the major device number used by the nvidia-uvm driver
    D=$(grep nvidia-uvm /proc/devices | awk '{print $1}')

    mknod -m 666 /dev/nvidia-uvm c "${D}" 0 1>/dev/null 2>&1
  else
    echo "fail"
    return 1
  fi
  echo "ok"
}

do_start() {
 local ver=$1
 local clean=$2
 local attach=$3
 local interactive=$4
 local volumes=""
 local envi=""
 local lxcfs_mounts=""
 local limits_mem=""
 local limits_cpu=""
 local nvidia_args=""
 local caps=""

 [[ ${clean} -eq 1 ]] && [[ ${attach} -eq 1 ]] && { echo "[E] -c and -a options cannot be used together!"; return; }

 [[ ATTACH_NVIDIA -eq 1 ]] && { _nvidia_cuda_init; local nvidia_args=$(_add_nvidia_mounts); echo "[i] Attaching NVIDIA stuff to container..."; } || echo -n

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
  local clean=$1
  __command "[I] Stopping container ..." 1 ${CONTAINER_BIN} stop -t 10 "${APPLICATION}"
  [[ ${clean} -eq 1 ]] && __command "[!] Removing container..." 1 ${CONTAINER_BIN} rm "${APPLICATION}"
}

do_logs() {
 ${CONTAINER_BIN} logs "${APPLICATION}"
}

do_build() {
  local ver=$1
  local _clean_flag=$2
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

upgrade_lib(){
  local _remote_ver=$(curl https://raw.githubusercontent.com/hapylestat/native_container_app/master/version 2>/dev/null)
  
  if ! __vercomp "${LIB_VERSION}" "${_remote_ver}"; then
   echo "Current version ${LIB_VERSION} are installed, while ${_remote_ver} are available"
   read -rep "Confirm upgrade (y/N): " answer
   if [[ "${answer}" != "y" ]]; then
    echo "Upgrade cancelled by user"
    return
   fi
   curl https://raw.githubusercontent.com/hapylestat/native_container_app/master/src/container.lib.sh -o "${DIR}/container.lib.sh" 2>/dev/null
   sed -i "s/LIB_VERSION=\"0.0.0\"/LIB_VERSION=\"${_remote_ver}\"/" "${DIR}/container.lib.sh"

  if [[ ! -f "${DIR}/.config" ]]; then
    echo "Downloading default configuration file"
    curl https://raw.githubusercontent.com/hapylestat/native_container_app/master/src/.config -o "${DIR}/.config" 2>/dev/null
  fi

   echo "Upgrade done, please referer to https://raw.githubusercontent.com/hapylestat/native_container_app/master/src/.config for new available conf options"
  else 
    echo "Lib is up to date"
  fi
}

show_help(){
 echo "Help is here...soon"
}

#=============================================
declare -A COMMANDS=(
 [INIT]=0
 [BUILD]=0
 [START]=0
 [STOP]=0
 [RELOAD]=0
 [LOGS]=0
 [UPDATE]=0
)

declare -A FLAGS=(
 [CLEAN]=0
 [ATTACH]=0
 [INTERACTIVE]=0
)


for i in "${@}"; do
  if [[ ${COMMANDS[${i^^}]+_} ]]; then
   COMMANDS[${i^^}]=1
   shift
  else case ${i,,} in
  -c|--clean)
    FLAGS[CLEAN]=1
    shift;;
  -a|--attach)
    FLAGS[ATTACH]=1
    shift;;
  -it|--interactive)
    FLAGS[INTERACTIVE]=1
    shift;;
  -v=*|--ver=*)
    VER="${i#*=}"
    shift;;
  help|-h|--help)
    show_help
    exit 0;;
 esac fi
done

if [[ ${COMMANDS[UPDATE]} -eq 1 ]]; then
  upgrade_lib
elif [[ ${COMMANDS[INIT]} -eq 1 ]]; then
  do_init
elif [[ ${COMMANDS[START]} -eq 1 ]]; then
  do_start "${VER}" "${FLAGS[CLEAN]}" "${FLAGS[ATTACH]}" "${FLAGS[INTERACTIVE]}"
elif [[ ${COMMANDS[STOP]} -eq 1 ]]; then
  do_stop "${FLAGS[CLEAN]}"
elif [[ ${COMMANDS[BUILD]} -eq 1 ]]; then
  do_build "${VER}" "${FLAGS[CLEAN]}"
elif [[ ${COMMANDS[LOGS]} -eq 1 ]]; then
  do_logs
else
  show_help
fi

exit $?
