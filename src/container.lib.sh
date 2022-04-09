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
 echo -n $(cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd)
}

DIR=$(__dir)


. "${DIR}/.config"


APPLICATION=${APPLICATION:-}
VER=${VER:-}
VOLUMES=${VOLUMES:-}           # ("ext_folder_name:container_folder_path" .. "....")
ENVIRONMENT=${ENVIRONMENT:-}   # ("variable name: content" "...")
CMD=${CMD:-}                   # path to application executable inside container
IP=${IP:-}
ATTACH_NVIDIA=${ATTACH_NVIDIA:-0}

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

__command(){
  local title="$1"
  local silent="$2"  # 0 or 1
  shift;shift

  [[ "${__DEBUG}" -eq 1 ]] && echo "Command: $@"

  echo -n "${title}..."

  if [[ ${silent} -eq 1 ]]; then
    $@ 1>/dev/null 2>&1
    local __ec=$?
    if [[ $__ec -eq 0 ]]; then
      echo "OK"
    else 
      echo "FAILED"
    fi
    return ${__ec}
  else
    $@
    return $?
  fi
}

verify_requested_resources(){
  local system_cpu_cores=$(nproc)
  local total_system_memory=$(grep MemTotal /proc/meminfo|awk '{print $2}')
  local total_system_memory=$((total_system_memory / 1024 / 1024))
  local is_error=0

  if [[ "${LIMITS[MEMORY]%.*}" -gt "${total_system_memory%.*}" ]]; then
    echo "[ERROR] Available system memory: ${total_system_memory%.*} GB, but requested ${LIMITS[MEMORY]%.*} GB"
    local is_error=1
  fi

  if [[ "${LIMITS[CPU]%.*}" -gt "${system_cpu_cores%.*}" ]]; then 
    echo "[ERROR] Available system cpu cores: ${system_cpu_cores}, but requested ${LIMITS[CPU]}"
    local is_error=1
  fi

  [[ ${is_error} -eq 1 ]] && exit 1
}

_add_nvidia_mounts(){
  local _args="--cap-add=ALL" # required 
  local _driver_version=$(nvidia-container-cli info|grep "NVRM"|awk -F ':' '{print $2}'|tr -d ' ')

  for _dev in $(find /dev -maxdepth 1 -name 'nvidia*'); do 
    local _args="${_args} --device ${_dev}"
  done 
  
  for item in $(nvidia-container-cli list|grep -v "dev"); do 
    if [[ ${item} == *".so"* ]]; then
      local _pure_path=$(echo ${item}|sed "s/.${_driver_version}//")
      local _args="${_args} -v ${item}:${item}:ro -v ${item}:${_pure_path}:ro -v ${item}:${_pure_path}.1:ro"
    else 
      local _args="${_args} -v ${item}:${item}:ro"
    fi
  done

  echo -n "${_args}"
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

 if [[ ${clean} -eq 1 ]] && [[ ${attach} -eq 1 ]]; then
  echo "[E] -c and -a options cannot be used together!"
  return
 fi

 verify_requested_resources
 if [[ ${LIMITS[CPU]%.*} -ne 0 ]]; then 
  local total_cores=$(nproc)
  local total_cores=$((total_cores - 1))
  local min_core=$((LIMITS[CPU]-1))
  local min_core=$((total_cores-min_core))
  echo "CPU cores set:"
  echo "- ${min_core}-${total_cores}"
  local limits_cpu="--cpuset-cpus=${min_core}-${total_cores}"
 fi

 if [[ ${LIMITS[CPU]%.*} -ne 0 ]]; then 
  echo "MEMORY limits:"
  echo "- ${LIMITS[MEMORY]}"
  local limits_mem="--memory=${LIMITS[MEMORY]}G"
 fi

 echo "LXS-FS extension is installed: you"
 [[ "${IS_LXCFS_ENABLED}" -eq 1 ]] && { local lxcfs_mounts=${LXC_FS_OPTS[*]}; echo "- YES"; } || { echo "- NO"; }

 echo "Container volumes:"
 for v in "${VOLUMES[@]}"; do
   local share=(${v//:/ })
   #  resolving here relative or absolute source paths
   local first_char=${share[0]:0:1}
   [[ "${first_char}" == "/" ]] && { local _src_dir=${share[0]}; } || { local _src_dir="${DIR}/storage/${share[0]}"; }

   local volumes="${volumes}-v ${_src_dir}:${share[1]} "
   echo " - ${_src_dir} => ${share[1]}"
 done
 
 echo "Environment variables:"
 for v in "${ENVIRONMENT[@]}"; do
   local _env=(${v//=/ })
   local envi="${envi}-e ${_env[0]}=${_env[1]} "
   echo " - ${_env[0]} = ${_env[1]}"
 done

 # network 
 [[ "${IP}" == "host" ]] && { local _net_argument="--net=host"; } || { local _net_argument="--ip=${IP}"; }

 # NS Isolation
 echo -n "NS_USER mapping: "
 if [[ "${NS_USER}" == "keep-id" ]]; then
   local __ns_arguments=""
   echo "none"
 elif [[ "${NS_USER:0:1}" == "@" ]]; then 
   local __ns_arguments="--user=${NS_USER:1}"
   echo "run as user"
 else
   echo "uid and gid mapping"
   local __ns_arguments="--subuidname=${NS_USER} --subgidname=${NS_USER}"
 fi

 echo "Container IP:"
 echo " - ${IP}"

 podman container exists "${APPLICATION}" 1>/dev/null 2>&1
 local is_exists=$?
 local action="start"

 [[ ATTACH_NVIDIA -eq 1 ]] && { local nvidia_args=$(_add_nvidia_mounts); echo "[i] Attaching NVIDIA stuff to container..."; } || echo -n

 if [[ ${is_exists} -eq 0 ]]; then
   __command "Stopping container" 1 podman stop "${APPLICATION}"
  [[ ${clean} -eq 1 ]] && { __command "[!] Removing already existing container..." 1 podman rm "${APPLICATION}"; local action="run"; }
 else
   local action="run"
 fi

 if [[ "${action}" == "start" ]]; then  
   [[ ${attach} -eq 1 ]] && local option="-a"  || local option=""
   [[ ${attach} == 0 ]] && local _silent=1 || local _silent=0 # flip attach value and store to _silent
   __command "[!] Starting container..." ${_silent} podman start "${option}" "${APPLICATION}"
 else 
   [[ ${interactive} -eq 1 ]] && { local action="run"; local options="-it --entrypoint=bash"; echo "[i] Interactive run..."; } || { local action="run"; local options="-d"; }
   [[ ${attach} -eq 1 ]] && { local action="create"; local options=""; }

  __command "[!] Creating and starting container..." 0 \
  podman ${action} ${limits_cpu} ${limits_mem}\
  "${__ns_arguments}"\
  --name "${APPLICATION}"\
  --hostname "${APPLICATION}"\
  ${options}\
  ${_net_argument}\
  ${lxcfs_mounts}\
  ${envi}\
  ${volumes}\
  ${nvidia_args}\
  "${APPLICATION}":"${ver}"

  [[ ${attach} -eq 1 ]] && podman start -a "${APPLICATION}"
 fi
}

do_stop() {
  local clean=$1
  __command "[I] Stopping container ..." 1 podman stop -t 10 "${APPLICATION}"
  [[ ${clean} -eq 1 ]] && __command "[!] Removing container..." 1 podman rm "${APPLICATION}"
}

do_logs() {
 podman logs ${APPLICATION}
}

do_build() {
  local ver=$1
  # podman build --build-arg VSCODE_VER=${ver} -t ${APPLICATION}:${ver} container
  podman build --build-arg APP_VER="${VER}" -t "${APPLICATION}":"${ver}" container
}

do_init(){
 local dirs=("container" "storage")
 local docker_mkdir=""
 local docker_volumes=""
 local volumes=""
 for v in "${VOLUMES[@]}"; do
   local share=(${v//:/ })
   local docker_mkdir="${docker_mkdir}RUN mkdir -p ${share[1]}\n"
   local docker_volumes="${docker_volumes}VOLUME ${share[1]}\n"
   local volumes="${volumes} ${share[0]}"
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
FROM centos:7
LABEL maintainer "hapy lestat"

ARG APP_VER
ENV APP_VER=\${APP_VER:-}

RUN yum install -y curl &&\\
#    ....packages to install here.......
    yum clean all
EOF

 echo -e "${docker_mkdir}" >> "${DIR}/container/Dockerfile"
 echo -e "${docker_volumes}" >> "${DIR}/container/Dockerfile" 

 if [[ ${ATTACH_NVIDIA} -eq 1 ]]; then
  echo "RUN echo -e \"\\n\\n#Required for NVidia integration\\nldconfig\\n\" >> /root/.bashrc" >> "${DIR}/container/Dockerfile"
 fi

 echo "CMD \"${CMD}\"" >> "${DIR}/container/Dockerfile"
 fi
 
 echo "Create volumes..."
 local _uid=$(grep "${NS_USER}" /etc/subuid|cut -d ':' -f 2)
 local _gid=$(grep "${NS_USER}" /etc/subgid|cut -d ':' -f 2)

 for v in "${volumes[@]}"; do
  echo -n " - mkdir storage/${v} ..."
  if [[ -d "${DIR}/storage/${v}" ]]; then
    echo "exist"
  else 
    mkdir -p "${DIR}/storage/${v}" 1>/dev/null 2>&1
   [[ $? -eq 0 ]] && echo "created" || echo "failed"
  fi
  local _uid=$(grep "${NS_USER}" /etc/subuid | cut -d ':' -f 2)
  local _gid=$(grep "${NS_USER}" /etc/subuid | cut -d ':' -f 2)
  echo " - permissions storage/${v} => ${_uid}:${_gid}, mode 700..."
  chown "${_uid}":"${_gid}" "${DIR}/storage/${v}"
  chmod 700 "${DIR}/storage/${v}"
 done
 
 echo -n "Creating systemd service file..."
 local service_name=$(basename "$0")
 local service_name=(${service_name//./ })
 local service_name=${service_name[0]}
 
 if [[ ! -f "${DIR}/${service_name}.service" ]]; then
 cat > "${DIR}/${service_name}.service" <<EOF
[Unit]
Description=Podman ${service_name}.service
Documentation=man:podman-generate-systemd(1)
Wants=network.target
After=network-online.target
RequiresMountsFor=/mnt/data/containers/storage /tmp/containers/storage

[Service]
Type=simple
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=on-failure
TimeoutStopSec=70
ExecStart=/usr/srv/_podman_apps/${service_name}/${service_name}.sh start -a
ExecStop=/usr/srv/_podman_apps/${service_name}/${service_name}.sh stop


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
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++));  do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
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
   echo "Upgrade done"
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
 [LOGS]=0
 [DOWNLOAD]=0
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

if [[ ${COMMANDS[DOWNLOAD]} -eq 1 ]]; then
  upgrade_lib
elif [[ ${COMMANDS[INIT]} -eq 1 ]]; then
  do_init
elif [[ ${COMMANDS[START]} -eq 1 ]]; then
  do_start "${VER}" "${FLAGS[CLEAN]}" "${FLAGS[ATTACH]}" "${FLAGS[INTERACTIVE]}"
elif [[ ${COMMANDS[STOP]} -eq 1 ]]; then
  do_stop "${FLAGS[CLEAN]}"
elif [[ ${COMMANDS[BUILD]} -eq 1 ]]; then
  do_build "${VER}"
elif [[ ${COMMANDS[LOGS]} -eq 1 ]]; then
  do_logs
else
  show_help
fi

exit $?
