#!/usr/bin/env bash

#=======================================================================#
# Copyright (C) 2020 - 2024 Dominik Willner <th33xitus@gmail.com>       #
#                                                                       #
# This file is part of KIAUH - Klipper Installation And Update Helper   #
# https://github.com/dw-0/kiauh                                         #
#                                                                       #
# This file may be distributed under the terms of the GNU GPLv3 license #
#=======================================================================#

set -e

#===================================================#
#============== INSTALL SWIERVISION ==============#
#===================================================#

function swiervision_systemd() {
  local services
  services=$(find "${SYSTEMD}" -maxdepth 1 -regextype posix-extended -regex "${SYSTEMD}/SwierVision.service")
  echo "${services}"
}

function install_swiervision() {
  ### return early if python version check fails
  if [[ $(python3_check) == "false" ]]; then
    local error="Versioncheck failed! Python 3.7 or newer required!\n"
    error="${error} Please upgrade Python."
    print_error "${error}" && return
  fi

  ### first, we create a backup of the full klipper_config dir - safety first!
  backup_config_dir

  ### install SwierVision
  swiervision_setup

  ### add swiervision to the update manager in moonraker.conf
  patch_swiervision_update_manager

  do_action_service "restart" "SwierVision"
}

function swiervision_setup() {
  local dep=(wget curl unzip dfu-util)
  dependency_check "${dep[@]}"
  status_msg "Cloning SwierVision from ${SWIERVISION_REPO} ..."

  # force remove existing SwierVision dir
  [[ -d ${SWIERVISION_DIR} ]] && rm -rf "${SWIERVISION_DIR}"

  # clone into fresh SwierVision dir
  cd "${HOME}" || exit 1
  if ! git clone "${SWIERVISION_REPO}" "${SWIERVISION_DIR}"; then
    print_error "Cloning SwierVision from\n ${SWIERVISION_REPO}\n failed!"
    exit 1
  fi

  status_msg "Installing SwierVision ..."
  if "${SWIERVISION_DIR}"/scripts/SwierVision-install.sh; then
    ok_msg "SwierVision successfully installed!"
  else
    print_error "SwierVision installation failed!"
    exit 1
  fi
}

#===================================================#
#=============== REMOVE SWIERVISION ==============#
#===================================================#

function remove_swiervision() {
  ### remove SwierVision dir
  if [[ -d ${SWIERVISION_DIR} ]]; then
    status_msg "Removing SwierVision directory ..."
    rm -rf "${SWIERVISION_DIR}" && ok_msg "Directory removed!"
  fi

  ### remove SwierVision VENV dir
  if [[ -d ${SWIERVISION_ENV} ]]; then
    status_msg "Removing SwierVision VENV directory ..."
    rm -rf "${SWIERVISION_ENV}" && ok_msg "Directory removed!"
  fi

  ### remove SwierVision service
  if [[ -e "${SYSTEMD}/SwierVision.service" ]]; then
    status_msg "Removing SwierVision service ..."
    do_action_service "stop" "SwierVision"
    do_action_service "disable" "SwierVision"
    sudo rm -f "${SYSTEMD}/SwierVision.service"

    ###reloading units
    sudo systemctl daemon-reload
    sudo systemctl reset-failed
    ok_msg "SwierVision Service removed!"
  fi

  ### remove SwierVision log
  if [[ -e "/tmp/SwierVision.log" ]]; then
    status_msg "Removing SwierVision log file ..."
    rm -f "/tmp/SwierVision.log" && ok_msg "File removed!"
  fi

  ### remove SwierVision log symlink in config dir
  if [[ -e "${KLIPPER_CONFIG}/SwierVision.log" ]]; then
    status_msg "Removing SwierVision log symlink ..."
    rm -f "${KLIPPER_CONFIG}/SwierVision.log" && ok_msg "File removed!"
  fi

  print_confirm "SwierVision successfully removed!"
}

#===================================================#
#=============== UPDATE SWIERVISION ==============#
#===================================================#

function update_swiervision() {
  local old_md5
  old_md5=$(md5sum "${SWIERVISION_DIR}/scripts/SwierVision-requirements.txt" | cut -d " " -f1)

  do_action_service "stop" "SwierVision"
  backup_before_update "swiervision"

  cd "${SWIERVISION_DIR}"
  git pull origin master -q && ok_msg "Fetch successfull!"
  git checkout -f master && ok_msg "Checkout successfull"

  if [[ $(md5sum "${SWIERVISION_DIR}/scripts/SwierVision-requirements.txt" | cut -d " " -f1) != "${old_md5}" ]]; then
    status_msg "New dependecies detected..."
    "${SWIERVISION_ENV}"/bin/pip install -r "${SWIERVISION_DIR}/scripts/SwierVision-requirements.txt"
    ok_msg "Dependencies have been installed!"
  fi

  ok_msg "Update complete!"
  do_action_service "start" "SwierVision"
}

#===================================================#
#=============== SWIERVISION STATUS ==============#
#===================================================#

function get_swiervision_status() {
  local sf_count status
  sf_count="$(swiervision_systemd | wc -w)"

  ### remove the "SERVICE" entry from the data array if a moonraker service is installed
  local data_arr=(SERVICE "${SWIERVISION_DIR}" "${SWIERVISION_ENV}")
  (( sf_count > 0 )) && unset "data_arr[0]"

  ### count+1 for each found data-item from array
  local filecount=0
  for data in "${data_arr[@]}"; do
    [[ -e ${data} ]] && filecount=$(( filecount + 1 ))
  done

  if (( filecount == ${#data_arr[*]} )); then
    status="Installed!"
  elif (( filecount == 0 )); then
    status="Not installed!"
  else
    status="Incomplete!"
  fi
  echo "${status}"
}

function get_local_swiervision_commit() {
  [[ ! -d ${SWIERVISION_DIR} || ! -d "${SWIERVISION_DIR}/.git" ]] && return

  local commit
  cd "${SWIERVISION_DIR}"
  commit="$(git describe HEAD --always --tags | cut -d "-" -f 1,2)"
  echo "${commit}"
}

function get_remote_swiervision_commit() {
  [[ ! -d ${SWIERVISION_DIR} || ! -d "${SWIERVISION_DIR}/.git" ]] && return

  local commit
  cd "${SWIERVISION_DIR}" && git fetch origin -q
  commit=$(git describe origin/master --always --tags | cut -d "-" -f 1,2)
  echo "${commit}"
}

function compare_swiervision_versions() {
  local versions local_ver remote_ver
  local_ver="$(get_local_swiervision_commit)"
  remote_ver="$(get_remote_swiervision_commit)"

  if [[ ${local_ver} != "${remote_ver}" ]]; then
    versions="${yellow}$(printf " %-14s" "${local_ver}")${white}"
    versions+="|${green}$(printf " %-13s" "${remote_ver}")${white}"
    # add moonraker to application_updates_available in kiauh.ini
    add_to_application_updates "swiervision"
  else
    versions="${green}$(printf " %-14s" "${local_ver}")${white}"
    versions+="|${green}$(printf " %-13s" "${remote_ver}")${white}"
  fi

  echo "${versions}"
}

#================================================#
#=================== HELPERS ====================#
#================================================#

function patch_swiervision_update_manager() {
  local patched="false"
  local moonraker_configs
  moonraker_configs=$(find "${KLIPPER_CONFIG}" -type f -name "moonraker.conf" | sort)

  for conf in ${moonraker_configs}; do
    if ! grep -Eq "^\[update_manager SwierVision\]\s*$" "${conf}"; then
      ### add new line to conf if it doesn't end with one
      [[ $(tail -c1 "${conf}" | wc -l) -eq 0 ]] && echo "" >> "${conf}"

      ### add SwierVisions update manager section to moonraker.conf
      status_msg "Adding SwierVision to update manager in file:\n       ${conf}"
      /bin/sh -c "cat >> ${conf}" << MOONRAKER_CONF

[update_manager SwierVision]
type: git_repo
path: ${HOME}/SwierVision
origin: https://github.com/SYNCRAFT-GITHUB/SwierVision.git
env: ${HOME}/.SwierVision-env/bin/python
requirements: scripts/SwierVision-requirements.txt
install_script: scripts/SwierVision-install.sh
MOONRAKER_CONF

    fi

    patched="true"
  done

  if [[ ${patched} == "true" ]]; then
    do_action_service "restart" "moonraker"
  fi
}
