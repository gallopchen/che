#!/bin/bash
#
# Copyright (c) 2012-2015 Codenvy, S.A.
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Eclipse Public License v1.0
# which accompanies this distribution, and is available at
# http://www.eclipse.org/legal/epl-v10.html
#
# Contributors:
#   Codenvy, S.A. - initial API and implementation
#

# See: https://sipb.mit.edu/doc/safe-shell/
set -e
set -o pipefail

# Run the finish function if exit signal initiated
trap exit SIGHUP SIGINT SIGTERM

function init_global_variables {

  # Short circuit
  JUMP_TO_END=false

  # For coloring console output
  BLUE='\033[1;34m'
  GREEN='\033[0;32m'
  NC='\033[0m'

  ### Define various error and usage messages
  WRONG="
Looks like something went wrong. Possible issues: 
  1. (Win | Mac) VirtualBox not installed          ==> Rerun Docker Toolbox installation
  2. (Win | Mac) Docker Machine not installed      ==> Rerun Docker Toolbox installation
  3. (Win | Mac) Docker is not reachable           ==> Docker VM failed to start
  4. (Win | Mac) Docker ok, but docker ps fails    ==> Docker environment variables not set properly
  5. (Linux) Docker is not reachable               ==> Install: wget -qO- https://get.docker.com/ | sh
  6. Could not find the Che app server             ==> Did /tomcat get moved away from CHE_HOME?
  7. Did you use the right parameter syntax?       ==> See usage

We have seen issues with VirtualBox on windows where your VM gets corrupted when your computer is suspended while the VM is still running. This will appear as SSH or ethernet connection issues. This is rare, but if encountered, current known solution is to uninstall VirtualBox and Docker Toolbox, and then reinstall.
"

  CHE_VARIABLES="
Che Environment Variables:
  (REQUIRED) JAVA_HOME                             ==> Location of Java runtime
  (REQUIRED: WIN|MAC) DOCKER_TOOLBOX_INSTALL_PATH  ==> Location of Docker Toolbox
  (REQUIRED: WIN|MAC) VBOX_MSI_INSTALL_PATH        ==> Location of VirtualBox  
  (OPTIONAL) CHE_HOME                              ==> Directory where Che is installed
  (OPTIONAL) CHE_LOCAL_CONF_DIR                    ==> Directory with custom Che .properties files
  (OPTIONAL) CHE_LOGS_DIR                          ==> Directory for Che output logs

  "

  USAGE="
Usage: 
  che [-i] [-i:tag] [-p:port] [-r:ip] [-m:vm] [-d] [run | start | stop]

     -i,      --image        Launches Che within a Docker container using latest image
     -i:tag,  --image:tag    Launches Che within a Docker container using specific image tag
     -p:port, --port:port    Port that Che server will use for HTTP requests; default=8080
     -r:ip,   --remote:ip    If Che clients are not localhost, set to IP address of Che server
     -m:vm,   --machine:vm   For Win & Mac, sets the docker-machine VM name to vm; default=default  
     -h,      --help         Show this help
     -d,      --debug        Use debug mode (prints command line options + app server debug)
     run                     Starts Che application server in current console
     start                   Starts Che application server in new console
     stop                    Stops Che application server

The -r flag sets the DOCKER_MACHINE_HOST system environment variable. Set this to the IP address of the node
that is running your Docker daemon. Only necessary to set this if on Linux and your browser clients are not 
localhost, ie they are remote. This property automatically set for Che on Windows and Mac."

  # Command line parameters
  USE_DOCKER=false
  CHE_DOCKER_TAG=latest
  CHE_PORT=8080
  CHE_IP=
  USE_HELP=false
  CHE_SERVER_ACTION=run
  VM=${CHE_DOCKER_MACHINE_NAME:-default}
  USE_DEBUG=false

  # Sets value of operating system
  WIN=false
  MAC=false
  LINUX=false
}

function usage {
  echo "$USAGE"
}

function error_exit {
  echo
  echo "$1"
  echo "$WRONG $CHE_VARIABLES $USAGE"
  JUMP_TO_END=true
}

function parse_command_line {

  for command_line_option in "$@"
  do
  case $command_line_option in
    -i|--image)
      USE_DOCKER=true
    ;;
    -i:*|--image:*)
      USE_DOCKER=true
      if [ "${command_line_option#*:}" != "" ]; then
        CHE_DOCKER_TAG="${command_line_option#*:}"
      fi
    ;;
    -p:*|--port:*)
      if [ "${command_line_option#*:}" != "" ]; then
        CHE_PORT="${command_line_option#*:}"
      fi
    ;;
    -r:*|--remote:*)
      if [ "${command_line_option#*:}" != "" ]; then
        CHE_IP="${command_line_option#*:}"
      fi
    ;;
    -m:*|--machine:*)
      if [ "${command_line_option#*:}" != "" ]; then
        VM="${command_line_option#*:}"
      fi
    ;;
    -h|--help)
      USE_HELP=true
      usage
      return
    ;;
    -d|--debug)
      USE_DEBUG=true
    ;;    
    start|stop|run)
      CHE_SERVER_ACTION=${command_line_option}
    ;;
    *)
      # unknown option
      error_exit "!!! You passed an unknown command line option."
    ;;
  esac
  done

  if $USE_DEBUG; then
    echo "USE_DOCKER: ${USE_DOCKER}"
    echo "CHE_DOCKER_TAG: ${CHE_DOCKER_TAG}"
    echo "CHE_PORT: ${CHE_PORT}"
    echo "CHE_IP: \"${CHE_IP}\""
    echo "CHE_DOCKER_MACHINE: ${VM}"
    echo "USE_HELP: ${USE_HELP}"
    echo "CHE_SERVER_ACTION: ${CHE_SERVER_ACTION}"
    echo "USE_DEBUG: ${USE_DEBUG}"
  fi
}

function determine_os {
  # Set OS.  Mac & Windows require VirtualBox and docker-machine.

  if [[ "${OSTYPE}" == "linux"* ]]; then
    # Linux
    LINUX=true
  elif [[ "${OSTYPE}" == "darwin"* ]]; then
    # Mac OSX
    MAC=true
  elif [[ "${OSTYPE}" == "cygwin" ]]; then
    # POSIX compatibility layer and Linux environment emulation for Windows
    WIN=true
  elif [[ "${OSTYPE}" == "msys" ]]; then
    # Lightweight shell and GNU utilities compiled for Windows (part of MinGW)
    WIN=true
  elif [[ "${OSTYPE}" == "win32" ]]; then
    # I'm not sure this can happen.
    WIN=true
  elif [[ "${OSTYPE}" == "freebsd"* ]]; then
    # FreeBSD
    LINUX=true
  else
    error_exit "We could not detect your operating system. Che is unlikely to work properly."
  fi

}

function set_environment_variables {
  ### Set the value of derived environment variables.
  ### Use values set by user, unless they are broken, then fix them
  # The base directory of Che
  if [ -z "${CHE_HOME}" ]; then
    export CHE_HOME="$(dirname "$(cd $(dirname ${0}) && pwd -P)")"
  fi

  if [[ "${CHE_IP}" != "" ]]; then
    export DOCKER_MACHINE_HOST="${CHE_IP}"
  fi

  # Convert Tomcat environment variables to POSIX format.
  if [[ "${JAVA_HOME}" == *":"* ]]
  then 
    JAVA_HOME=$(echo /"${JAVA_HOME}" | sed  's|\\|/|g' | sed 's|:||g')
  fi

  if [[ "${CHE_HOME}" == *":"* ]]
  then 
    CHE_HOME=$(echo /"${CHE_HOME}" | sed  's|\\|/|g' | sed 's|:||g')
  fi

  # Che configuration directory - where .properties files can be placed by user
  if [ -z "${CHE_LOCAL_CONF_DIR}" ]; then
    export CHE_LOCAL_CONF_DIR="${CHE_HOME}/conf/"
  fi

  # Sets the location of the application server and its executables
  export CATALINA_HOME="${CHE_HOME}/tomcat"

  # Convert windows path name to POSIX
  if [[ "${CATALINA_HOME}" == *":"* ]]
  then 
    CATALINA_HOME=$(echo /"${CATALINA_HOME}" | sed  's|\\|/|g' | sed 's|:||g')
  fi

  export CATALINA_BASE="${CHE_HOME}/tomcat"
  export ASSEMBLY_BIN_DIR="${CATALINA_HOME}/bin"

  # Global logs directory
  if [ -z "${CHE_LOGS_DIR}" ]; then
    export CHE_LOGS_DIR="${CATALINA_HOME}/logs/"
  fi

}

function get_docker_ready {
  # Create absolute file names for docker and docker-machine
  # DOCKER_TOOLBOX_INSTALL_PATH set globally by Docker Toolbox installer
  if [ "${WIN}" == "true" ]; then
    if [ ! -z "${DOCKER_TOOLBOX_INSTALL_PATH}" ]; then
      export DOCKER_MACHINE=${DOCKER_TOOLBOX_INSTALL_PATH}\\docker-machine.exe
      export DOCKER=${DOCKER_TOOLBOX_INSTALL_PATH}\\docker.exe
    else
      error_exit "!!! DOCKER_TOOLBOX_INSTALL_PATH environment variable not set. Add it or rerun Docker Toolbox installation.!!!"
      return
    fi
  elif [ "${MAC}" == "true" ]; then
    export DOCKER_MACHINE=/usr/local/bin/docker-machine
    export DOCKER=/usr/local/bin/docker
  elif [ "${LINUX}" == "true" ]; then
    export DOCKER_MACHINE=
    export DOCKER=/usr/bin/docker
  fi 

  ### If Windows or Mac, launch docker-machine, if necessary
  if [ "${WIN}" == "true" ] || [ "${MAC}" == "true" ]; then
    # Path to run VirtualBox on the command line - used for creating VMs
    if [ ! -z "${VBOX_MSI_INSTALL_PATH}" ]; then
      VBOXMANAGE=${VBOX_MSI_INSTALL_PATH}VBoxManage.exe
    else 
      VBOXMANAGE=/usr/local/bin/VBoxManage
    fi

    if [ ! -f "${DOCKER_MACHINE}" ]; then
      error_exit "!!! Could not find docker-machine executable. Win: DOCKER_TOOLBOX_INSTALL_PATH env variable not set. Add it or rerun Docker Toolbox installation. Mac: Expected docker-machine at /usr/local/bin/docker-machine. !!!"
      return
    fi

    if [ ! -f "${VBOXMANAGE}" ]; then
      error_exit "!!! Could not find VirtualBox. Win: VBOX_MSI_INSTALL_PATH env variable not set. Add it or rerun Docker Toolbox installation. Mac: Expected Virtual Box at /usr/local/bin/VBoxManage. !!!"
      return
    fi

    # Test to see if the VM we need is already running
    # Added || true to not fail due to set -e
    "${VBOXMANAGE}" showvminfo $VM &> /dev/null || VM_EXISTS_CODE=$? || true 

    if [ "${VM_EXISTS_CODE}" == "1" ]; then
      echo "Creating docker machine named $VM..."
      "${DOCKER_MACHINE}" rm -f $VM &> /dev/null || :
      rm -rf ~/.docker/machine/machines/$VM
      "${DOCKER_MACHINE}" create -d virtualbox $VM
    else
      echo -e "Docker machine named ${GREEN}$VM${NC} already exists..."
    fi

    VM_STATUS=$("${DOCKER_MACHINE}" status $VM 2>&1)

    if [ "${VM_STATUS}" != "Running" ]; then
      echo -e "Docker machine named ${GREEN}$VM${NC} is not running."
      echo -e "Starting docker machine named ${GREEN}$VM${NC}..."
      "${DOCKER_MACHINE}" start $VM
      yes | "${DOCKER_MACHINE}" regenerate-certs $VM || true
    fi

    echo -e "Setting environment variables for machine ${GREEN}$VM${NC}..."
    eval "$("${DOCKER_MACHINE}" env --shell=bash $VM)"
  fi
  ### End logic block to create / remove / start docker-machine VM

  # Docker should be available, either in a VM or natively.
  # Test to see if docker binary is installed
  if [ ! -f "${DOCKER}" ]; then
    error_exit "!!! Could not find Docker client. Expected at Windows: %DOCKER_TOOLBOX_INSTALL_PATH%\\docker.exe, Mac: /usr/local/bin/docker, Linux: /usr/bin/docker."
    return
  fi

  # Test to see that docker command works
  "${DOCKER}" &> /dev/null || DOCKER_EXISTS=$? || true

  if [ "${DOCKER_EXISTS}" == "1" ]; then
    error_exit "!!! We found the 'docker' binary, but running 'docker' failed. Is a docker symlink broken?"
    return
  fi

  # Test to verify that docker can reach the VM
  "${DOCKER}" ps &> /dev/null || DOCKER_VM_REACHABLE=$? || true

  if [ "${DOCKER_VM_REACHABLE}" == "1" ]; then
    error_exit "!!! Running 'docker' succeeded, but 'docker ps' failed. This usually means that docker cannot reach its daemon."
    return
  fi

  if [ "${WIN}" == "true" ] || [ "${MAC}" == "true" ]; then
    echo -e "${BLUE}Docker${NC} is configured to use vbox docker-machine named ${GREEN}$VM${NC} with IP ${GREEN}$("${DOCKER_MACHINE}" ip $VM)${NC}..."
  else
    echo "Docker is natively installed and reachable..."
  fi  
}

# Added || true to all pipelines to allow for failure
# We set -o pipefail to cause failures in pipe processing, but not needed for this functional
function strip_url {
  # extract the protocol
  proto="`echo $1 | grep '://' | sed -e's,^\(.*://\).*,\1,g'`" || true
  
  # remove the protocol
  url=`echo $1 | sed -e s,$proto,,g` || true

  # extract the user and password (if any)
  userpass=`echo $url | grep @ | cut -d@ -f1` || true
  pass=`echo $userpass | grep : | cut -d: -f2` || true


  if [ -n "$pass" ]; then
      user=`echo $userpass | grep : | cut -d: -f1` || true
  else
      user=$userpass
  fi

  # extract the host and remove the port
  hostport=`echo $url | sed -e s,$userpass@,,g | cut -d/ -f1` || true
  port=`echo $hostport | grep : | cut -d: -f2` || true
  if [ -n "$port" ]; then
      host=`echo $hostport | grep : | cut -d: -f1` || true
  else
      host=$hostport
  fi

  # extract the path (if any)
  path="`echo $url | grep / | cut -d/ -f2-`" || true

}

function print_client_connect {
  if [ "${USE_DOCKER}" == "false" ]; then 
    echo "

############## HOW TO CONNECT YOUR CHE CLIENT ###############
After Che server has booted, you can connect your clients by:
1. Open browser to http://localhost:${CHE_PORT}, or:
2. Open native chromium app.
#############################################################

"
  else 
    echo "

############## HOW TO CONNECT YOUR CHE CLIENT ###############
After Che server has booted, you can connect your clients by:
1. Open browser to http://${host}:${CHE_PORT}, or:
2. Open native chromium app.
#############################################################

"

  fi
}

function call_catalina {

  # Test to see that Che application server is where we expect it to be
  if [ ! -d "${ASSEMBLY_BIN_DIR}" ]; then
    error_exit
    return
  fi

  ### Cannot add this in setenv.sh.
  ### We do the port mapping here, and this gets inserted into server.xml when tomcat boots
  [ -z "${JAVA_OPTS}" ]  && export JAVA_OPTS="-Dport.http=${CHE_PORT}"
  [ -z "${SERVER_PORT}" ]  && export SERVER_PORT=${CHE_PORT}

  # Launch the Che application server, passing in command line parameters
  if [[ "${USE_DEBUG}" == true ]]; then
    "${ASSEMBLY_BIN_DIR}"/catalina.sh jpda ${CHE_SERVER_ACTION}
  else
    "${ASSEMBLY_BIN_DIR}"/catalina.sh ${CHE_SERVER_ACTION}
  fi
}

function stop_che_server {

  if ! $USE_DOCKER; then
    echo -e "Stopping Che server running on localhost:${CHE_PORT}"
    call_catalina >/dev/null 2>&1
  else
    echo -e "Stopping Che server running in docker container."

    DOCKER_EXEC="sudo service docker stop && /home/user/che/bin/che.sh stop"
    "${DOCKER}" exec che $DOCKER_EXEC &>/dev/null 2>&1 || DOCKER_EXIT=$? || true

    echo -e "Stopping docker container named che."
    "${DOCKER}" stop che &>/dev/null 2>&1 || DOCKER_EXIT=$? || true
  fi
}

function kill_and_launch_docker {

  echo "Either che container does not exist, or duplicate conflict was discovered."
  echo -e "Removing any old containers and launching a new one using image codenvy/che:${CHE_DOCKER_TAG} and docker command:"
  "${DOCKER}" kill che &> /dev/null || true
  "${DOCKER}" rm che &> /dev/null || true

  if $WIN || $MAC ; then
     # This DOCKER_HOST is environment variable set by docker-machine - location of VM w/ Docker
    set -x
    "${DOCKER}" run --privileged -e \"DOCKER_MACHINE_HOST=${host}\" --name che -it -p ${CHE_PORT}:${CHE_PORT} -p 32768-32788:32768-32788 codenvy/che:${CHE_DOCKER_TAG} #&> /dev/null
  else
    set -x
    "${DOCKER}" run --privileged -e '"'DOCKER_MACHINE_HOST=${DOCKER_MACHINE_HOST}'"' --name che -it -p ${CHE_PORT}:${CHE_PORT} -p 32768-32788:32768-32788 codenvy/che:${CHE_DOCKER_TAG} #&> /dev/null
  fi      
  set +x
}

function launch_che_server {

  if $WIN || $MAC ; then
    strip_url $DOCKER_HOST
  else
    host=localhost
  fi      

  print_client_connect

  # Launch Che natively as a tomcat server
  if ! $USE_DOCKER; then
    call_catalina

  # Launch Che as a docker image
  else
    
    echo "Starting Che server in docker container named che."

    # Check to see if the Che docker was not properly shut down
    "${DOCKER}" inspect che &> /dev/null || DOCKER_INSPECT_EXIT=$? || true
    if [ "${DOCKER_INSPECT_EXIT}" == "1" ]; then
      kill_and_launch_docker
      return
    fi

    echo "Found a container named che. Attempting restart."
    "${DOCKER}" start che &>/dev/null || DOCKER_EXIT=$? || true

    if [ "${DOCKER_EXIT}" == "1" ]; then
      echo "Initial start of docker container failed... Attempting docker restart and exec."
      DOCKER_EXEC="sudo service docker start && /home/user/che/bin/che.sh start" >/dev/null 2>&1
      "${DOCKER}" exec che $DOCKER_EXEC || DOCKER_EXIT=$? || true    
    fi

    # If either command fails, then wipe any existing image and restarting
    if [ "${DOCKER_EXIT}" == "1" ]; then
      kill_and_launch_docker
      return
    fi

    echo "Docker container named Che successfully started."

  fi
}

init_global_variables
parse_command_line "$@"
determine_os

if [ "${USE_HELP}" == "false" ] && [ "${JUMP_TO_END}" == "false" ]; then

  # Call function
  set_environment_variables

  ### Variables are all set.  Get Docker ready
  get_docker_ready

  ### Launch or shut down Che server
  if [ "${JUMP_TO_END}" == "false" ]; then 
    if [ "${CHE_SERVER_ACTION}" == "stop" ]; then
      stop_che_server 
    else
      launch_che_server
    fi
  fi
fi