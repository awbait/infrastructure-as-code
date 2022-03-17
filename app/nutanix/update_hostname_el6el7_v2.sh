# Copyright (c) 2020 Nutanix Inc. All rights reserved.
#
# Disclaimer: Usage of this tool must be under guidance of Nutanix Support or an authorised partner
# Summary: This script automates steps that need to be run on AHV host during host rename procedure
# Version of the script: Version 2
# Compatible software version(s): AHV 20170830.X, 20190916.X
# Brief syntax usage: bash /tmp/update_hostname_el6el7_v2.sh <new-host-name>
# Caveats: The aforementioned syntax usage assumes that the script has already been downloaded in the recommended location, namely, the /tmp folder.
#          Once script is executed on AHV host, acropolis service should be restarted on CVM running on the same host.
#          Check "CHANGING THE ACROPOLIS HOST NAME" chapter in "AHV Administration Guide" on Nutanix portal for complete description of the procedure


#!/bin/bash

# debug off
set +x

usage() {
  local _script=$(basename $1)
  local _exit_code=$2

  echo "Usage: "
  echo " $_script <hostname>"
  echo "    <hostname> - the new name of the hots"
  echo 
  exit $_exit_code
}

check_rc() {
  if [ $? -ne 0 ]; then
    echo "error"
  else
    echo "ok"
  fi
}

el6_update_hostname() {
  hostname $1
  check_rc
}

el7_update_hostname() {
	hostnamectl set-hostname $1 --static
  check_rc
}

update_hostname() {
  local _crt=$1
  local _new=$2
  local _distro=$3
  
  echo -n "update hostname from '$_crt' to '$_new' ... "
  case $_distro in
    "el6") el6_update_hostname $_new ;;
    "el7") el7_update_hostname $_new ;;
  esac
}

el6_restart_rsyslog() {
  service rsyslog restart > /dev/null 2>&1
  check_rc
}

el7_restart_rsyslog() {
  systemctl restart rsyslog
  check_rc
}

restart_rsyslog() {
  local _distro=$1

  echo -n "restart service rsyslog ... "
  case $_distro in
    "el6") el6_restart_rsyslog ;;
    "el7") el7_restart_rsyslog ;;
  esac
}

el6_restart_lldpd() {
  service lldpd restart > /dev/null 2>&1
  check_rc
}

el7_restart_lldpd() {
  systemctl restart lldpd
  check_rc
}

restart_lldpd() {
  local _distro=$1

  echo -n "restart service lldpd ... "
  case $_distro in
    "el6") el6_restart_lldpd ;;
    "el7") el7_restart_lldpd ;;
  esac
}

reload_auditd_config() {
  echo -n "reload service auditd's config ... "
  pkill -SIGHUP auditd -x
  check_rc
}

update_etc_hostname() {
  local _crt=$1
  local _new=$2

  echo -n "update config file: $ETC_HOSTNAME_F ... "
  if [ -w $ETC_HOSTNAME_F ]; then
    echo $_new > $ETC_HOSTNAME_F
    check_rc
  else
    echo "skipped (file missing or read-only)"
  fi
}

update_etc_hosts() {
  local _crt=$1
  local _new=$2

  echo -n "update config file: $ETC_HOSTS_F ... "
  sed -i -r "s/^(127.0.0.1[[:blank:]]+)$_crt$/\1$_new/" $ETC_HOSTS_F
  check_rc
}

update_etc_sysconfig_network() {
  local _crt=$1
  local _new=$2

  echo -n "update config file: $ETC_SYSCONFIG_NETWORK_F ... "
  if [ -w $ETC_SYSCONFIG_NETWORK_F ]; then
    sed -i -r "s/^(HOSTNAME[[:blank:]]*=[[:blank:]]*)$_crt$/\1$_new/" $ETC_SYSCONFIG_NETWORK_F
    check_rc
  else
    echo "skipped (file missing or read-only)"
  fi
}

el7_update_ovsdb_server_database() {
  local _new=$1
  if [ -r $VAR_RUN_OVSDB_SERVER_PID_F ]; then
    ovs-vsctl set Open_vSwitch . external_ids:hostname=$_new
    check_rc
  else
    echo "not running"
  fi
}

update_ovsdb_server_database() {
  _new=$1
  _distro=$2

  echo -n "update ovsdb-server database ... "
  case "$_distro" in
    "el6") echo "skipped" ;;
    "el7") el7_update_ovsdb_server_database $_new ;;
  esac
}

el6_get_hostname() {
  local _el6_hostname=

  if [ -r $ETC_SYSCONFIG_NETWORK_F ]; then
    _el6_hostname=$(grep ^HOSTNAME $ETC_SYSCONFIG_NETWORK_F | tail -n 1 | tr -d ' \t' | cut -d '=' -f 2)
  else
    echo "error: static hostname source ($ETC_SYSCONFIG_NETWORK_F) is missing"
    logger "error: static hostname source ($ETC_SYSCONFIG_NETWORK_F) is missing"
    exit $ERR_MISSING_CONFIG
  fi
  echo $_el6_hostname
}

el7_get_hostname() {
  local _el7_hostname=

  if [ -r $ETC_HOSTNAME_F ]; then
    _el7_hostname=$(grep -v ^# /etc/hostname | tail -n 1)
  else
    echo "error: static hostname source ($ETC_HOSTNAME_F) is missing"
    logger "error: static hostname source ($ETC_HOSTNAME_F) is missing"
    exit $ERR_MISSING_CONFIG
  fi
  echo $_el7_hostname
}

get_hostname() {
  local _distro=$1
  local _crt_hostname=$2 
  local _transient_hostname=$(hostname)

  case "$_distro" in
    "el6")
      local _static_hostname=$(el6_get_hostname) ;;
    "el7")
      local _static_hostname=$(el7_get_hostname) ;;
  esac
  
  if [ "$_transient_hostname" != "$_static_hostname" ]; then
    echo "warning: transient hostname [$_transient_hostname] and static hostname [$_static_hostname] differ"
    logger "warning: transient hostname [$_transient_hostname] and static hostname [$_static_hostname] differ"
  fi
  eval $_crt_hostname="'$_static_hostname'"
}

if [ $# -lt 1 ]; then
  usage $0 $ERR_INVALID_PARAMS
fi

generate_report() {
  local _distro=$1
  local _old_hostname=$2
  local _new_hostname=$3
  local _stage=$4
  local _log="/var/log/update_hostname.${_distro}.${_stage}.log"
  local _hostname=$(hostname)
  local _lldpd_status=$(lldpcli show chassis)
  local _etc_hosts_content=$(cat $ETC_HOSTS_F)
  local _ovsdb_server_db=$(ovs-vsctl get Open_vSwitch . external-ids)

  if [ "$_stage" == "ini" ]; then
    local _syslog_audispd=$(grep -E -m 10 "^.*$_old_hostname audispd.*$" /var/log/messages)
  else
    local _syslog_audispd=$(grep -E -A 10 "^.*$_new_hostname audispd.*Starting reconfigure.*$" /var/log/messages)
  fi

  rm -f $_log

  echo -e "*** OS Distro:\n$_distro\n" >> $_log
  echo -e "*** Old Hostname:\n$_old_hostname\n" >> $_log
  echo -e "*** Current Hostname:\n${_hostname}\n" >> $_log
  echo -e "*** New Hostname:\n${_new_hostname}\n" >> $_log
  echo -e "*** LLDPD:\n${_lldpd_status}\n" >> $_log
  echo -e "*** $ETC_HOSTS_F:\n${_etc_hosts_content}\n" >> $_log

  if [ -r $ETC_HOSTNAME_F ]; then
    local _etc_hostname_content=$(cat $ETC_HOSTNAME_F)
    echo -e "*** $ETC_HOSTNAME_F:\n${_etc_hostname_content}\n" >> $_log 
  fi

  if [ -r $ETC_SYSCONFIG_NETWORK_F ]; then
    local _etc_sysconfig_network_content=$(cat $ETC_SYSCONFIG_NETWORK_F)
    echo -e "*** $ETC_SYSCONFIG_NETWORK_F:\n${_etc_sysconfig_network_content}\n" >> $_log 
  fi

  if [ "$DISTRO" == "el7" ]; then
    echo -e "*** Open_vSwitch:\n${_ovsdb_server_db}\n" >> $_log
  fi
  echo -e "*** Syslog/Audispd:\n${_syslog_audispd}\n" >> $_log
}

ERR_INVALID_PARAMS=1
ERR_UNKNOWN_DISTRO=2
ERR_MISSING_CONFIG=3

ETC_HOSTS_F=/etc/hosts
ETC_HOSTNAME_F=/etc/hostname
ETC_SYSCONFIG_NETWORK_F=/etc/sysconfig/network
VAR_RUN_OVSDB_SERVER_PID_F=/var/run/openvswitch/ovsdb-server.pid

DISTRO=$(cat /etc/nutanix-release | cut -d '.' -f 1)

#check the distribution right from the begining
if [ "$DISTRO" != "el6" ] && [ "$DISTRO" != "el7" ]; then
  echo "error: unknown Linux distribution -> $DISTRO"
  logger "error: unknown Linux distribution -> $DISTRO"
  exit $ERR_UNKNOWN_DISTRO
fi

echo "OS Distribution: $DISTRO"

NEW_HOSTNAME=$1

if echo "$NEW_HOSTNAME" | grep -q -E '^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$' && [ ${#NEW_HOSTNAME} -le 64 ]
then
    echo "Hostname valid."
else
    echo -e "Hostname is invalid.\nThe maximum length is 64 characters.\nAllowed characters are uppercase and lowercase letters (A-Z and a-z), decimal digits (0-9), dots (.), and hyphens (-).\nThe name must start and end with a number or letter."
    exit 1
fi

get_hostname $DISTRO CRT_HOSTNAME

echo "Hostname: $CRT_HOSTNAME"

STAGE="ini"
generate_report $DISTRO $CRT_HOSTNAME $NEW_HOSTNAME $STAGE

update_hostname $CRT_HOSTNAME $NEW_HOSTNAME $DISTRO
restart_rsyslog $DISTRO
restart_lldpd $DISTRO
reload_auditd_config

update_etc_hosts $CRT_HOSTNAME $NEW_HOSTNAME
update_etc_hostname $CRT_HOSTNAME $NEW_HOSTNAME
update_etc_sysconfig_network $CRT_HOSTNAME $NEW_HOSTNAME

update_ovsdb_server_database $NEW_HOSTNAME $DISTRO

STAGE="fini"
generate_report $DISTRO $CRT_HOSTNAME $NEW_HOSTNAME $STAGE
