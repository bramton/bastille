#!/bin/sh
#
# Copyright (c) 2018-2024, Christer Edwards <christer.edwards@gmail.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Source config file
. /usr/local/etc/bastille/bastille.conf

COLOR_RED=
COLOR_GREEN=
COLOR_YELLOW=
COLOR_RESET=

bastille_root_check() {
    if [ "$(id -u)" -ne 0 ]; then
        ## permission denied
        error_notify "Bastille: Permission Denied"
        error_exit "root / sudo / doas required"
    fi
}

enable_color() {
    . /usr/local/share/bastille/colors.pre.sh
}

# If "NO_COLOR" environment variable is present, or we aren't speaking to a
# tty, disable output colors.
if [ -z "${NO_COLOR}" ] && [ -t 1 ]; then
    enable_color
fi

# Error/Info functions
error_notify() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}" 1>&2
}

error_continue() {
    error_notify "$@"
    # Disabling this shellcheck as we only ever call it inside of a loop
    # shellcheck disable=SC2104
    continue
}

# Notify message on error and exit
error_exit() {
    error_notify "$@"
    exit 1
}

info() {
    echo -e "${COLOR_GREEN}$*${COLOR_RESET}"
}

warn() {
    echo -e "${COLOR_YELLOW}$*${COLOR_RESET}"
}

check_target_exists() {
    local _TARGET="${1}"
    if [ ! -d "${bastille_jailsdir}"/"${_TARGET}" ]; then
        return 1
    else
        return 0
    fi
}

check_target_is_running() {
    local _TARGET="${1}"
    if [ ! "$(/usr/sbin/jls name | awk "/^${_TARGET}$/")" ]; then
        return 1
    else
        return 0
    fi
}

check_target_is_stopped() {
    local _TARGET="${1}"
    if [ "$(/usr/sbin/jls name | awk "/^${_TARGET}$/")" ]; then
        return 1
    else
        return 0
    fi
}

generate_static_mac() {
    local jail_name="${1}"
    local external_interface="${2}"
    local external_interface_mac="$(ifconfig ${external_interface} | grep ether | awk '{print $2}' | sed 's#:##g')"
    local macaddr_prefix="$(echo -n "${external_interface_mac}" | sha256 | cut -b -6 | sed 's/\([0-9a-fA-F][0-9a-fA-F]\)\([0-9a-fA-F][0-9a-fA-F]\)\([0-9a-fA-F]\)/\1:\2:\3/')"
    local macaddr_suffix="$(echo -n "${jail_name}" | sha256 | cut -b -5 | sed 's/\([0-9a-fA-F][0-9a-fA-F]\)\([0-9a-fA-F][0-9a-fA-F]\)\([0-9a-fA-F]\)/\1:\2:\3/')"
    if [ -z "${macaddr_prefix}" ] || [ -z "${macaddr_suffix}" ]; then
        error_notify "Failed to generate MAC address."
    fi
    macaddr="${macaddr_prefix}:${macaddr_suffix}"
    export macaddr
}

generate_vnet_jail_netblock() {
    local jail_name="$1"
    local use_unique_bridge="$2"
    local external_interface="$3"
    generate_static_mac "${jail_name}" "${external_interface}"
    ## determine number of containers + 1
    ## iterate num and grep all jail configs
    ## define uniq_epair
    local jail_list="$(bastille list jails)"
    if [ -n "${jail_list}" ]; then
        local list_jails_num="$(echo "${jail_list}" | wc -l | awk '{print $1}')"
        local num_range=$((list_jails_num + 1))
        for _num in $(seq 0 "${num_range}"); do
            if ! grep -q "e[0-9]b_bastille${_num}" "${bastille_jailsdir}"/*/jail.conf; then
                if ! grep -q "epair${_num}" "${bastille_jailsdir}"/*/jail.conf; then
                    local uniq_epair="bastille${_num}"
                    local uniq_epair_bridge="${_num}"
                    break
                fi
            fi
        done
    else
        local uniq_epair="bastille0"
        local uniq_epair_bridge="0"
    fi
    if [ -n "${use_unique_bridge}" ]; then
        ## generate bridge config
        cat <<-EOF
  vnet;
  vnet.interface = e${uniq_epair_bridge}b_${jail_name};
  exec.prestart += "ifconfig epair${uniq_epair_bridge} create";
  exec.prestart += "ifconfig ${external_interface} addm epair${uniq_epair_bridge}a";
  exec.prestart += "ifconfig epair${uniq_epair_bridge}a up name e${uniq_epair_bridge}a_${jail_name}";
  exec.prestart += "ifconfig epair${uniq_epair_bridge}b up name e${uniq_epair_bridge}b_${jail_name}";
  exec.prestart += "ifconfig e${uniq_epair_bridge}a_${jail_name} ether ${macaddr}a";
  exec.prestart += "ifconfig e${uniq_epair_bridge}b_${jail_name} ether ${macaddr}b";
  exec.poststop += "ifconfig ${external_interface} deletem e${uniq_epair_bridge}a_${jail_name}";
  exec.poststop += "ifconfig e${uniq_epair_bridge}a_${jail_name} destroy";
EOF
    else
        ## generate config
        cat <<-EOF
  vnet;
  vnet.interface = e0b_${uniq_epair};
  exec.prestart += "jib addm ${uniq_epair} ${external_interface}";
  exec.prestart += "ifconfig e0a_${uniq_epair} ether ${macaddr}a";
  exec.prestart += "ifconfig e0b_${uniq_epair} ether ${macaddr}b";
  exec.prestart += "ifconfig e0a_${uniq_epair} description \"vnet host interface for Bastille jail ${jail_name}\"";
  exec.poststop += "jib destroy ${uniq_epair}";
EOF
    fi
}

set_target() {
    local _TARGET="${1}"
    if [ "${_TARGET}" = ALL ] || [ "${_TARGET}" = all ]; then
        target_all_jails
    else
        check_target_exists "${_TARGET}" || error_exit "Jail not found \"${_TARGET}\""
        JAILS="${_TARGET}"
        TARGET="${_TARGET}"
        export JAILS
        export TARGET
    fi
}

set_target_single() {
    local _TARGET="${1}"
    if [ "${_TARGET}" = ALL ] || [ "${_TARGET}" = all ]; then
        error_exit "[all|ALL] not supported with this command."
    else
        check_target_exists "${_TARGET}" || error_exit "Jail not found \"${_TARGET}\""
        JAILS="${_TARGET}"
        TARGET="${_TARGET}"
        export JAILS
        export TARGET
    fi
}

target_all_jails() {
    local _JAILS="$(bastille list jails)"
    JAILS=""
    for _jail in ${_JAILS}; do
        if [ -d "${bastille_jailsdir}/${_jail}" ]; then
            JAILS="${JAILS} ${_jail}"
        fi
    done
    export JAILS
}

checkyesno() {
    ## copied from /etc/rc.subr -- cedwards (20231125)
    ## issue #368 (lowercase values should be parsed)
    ## now used for all bastille_zfs_enable=YES|NO tests
    ## example: if checkyesno bastille_zfs_enable; then ...
    ## returns 0 for enabled; returns 1 for disabled
    eval _value=\$${1}
    case $_value in
    [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]|1)
        return 0
        ;;
    [Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff]|0)
        return 1
        ;;
    *)
        warn "\$${1} is not set properly - see rc.conf(5)."
        return 1
        ;;
    esac
}

