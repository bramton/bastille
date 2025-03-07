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

. /usr/local/share/bastille/common.sh
. /usr/local/etc/bastille/bastille.conf

usage() {
    error_exit "Usage: bastille clone TARGET NEW_NAME IPADDRESS"
}

# Handle special-case commands first
case "$1" in
help|-h|--help)
    usage
    ;;
esac

if [ $# -ne 2 ]; then
    usage
fi

bastille_root_check

NEWNAME="${1}"
IP="${2}"

validate_ip() {
    IPX_ADDR="ip4.addr"
    IP6_MODE="disable"
    ip6=$(echo "${IP}" | grep -E '^(([a-fA-F0-9:]+$)|([a-fA-F0-9:]+\/[0-9]{1,3}$))')
    if [ -n "${ip6}" ]; then
        info "Valid: (${ip6})."
        IPX_ADDR="ip6.addr"
        # shellcheck disable=SC2034
        IP6_MODE="new"
    else
        local IFS
        if echo "${IP}" | grep -Eq '^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/([0-9]|[1-2][0-9]|3[0-2]))?$'; then
            TEST_IP=$(echo "${IP}" | cut -d / -f1)
            IFS=.
            set ${TEST_IP}
            for quad in 1 2 3 4; do
                if eval [ \$$quad -gt 255 ]; then
                    error_exit "Invalid: (${TEST_IP})"
                fi
            done
            if ifconfig | grep -qwF "${TEST_IP}"; then
                warn "Warning: IP address already in use (${TEST_IP})."
            else
                info "Valid: (${IP})."
            fi
        else
            error_exit "Invalid: (${IP})."
        fi
    fi
}

update_jailconf() {
    # Update jail.conf
    JAIL_CONFIG="${bastille_jailsdir}/${NEWNAME}/jail.conf"
    if [ -f "${JAIL_CONFIG}" ]; then
        if ! grep -qw "path = ${bastille_jailsdir}/${NEWNAME}/root;" "${JAIL_CONFIG}"; then
 	    sed -i '' "s|host.hostname = ${TARGET};|host.hostname = ${NEWNAME};|" "${JAIL_CONFIG}"
            sed -i '' "s|exec.consolelog = .*;|exec.consolelog = ${bastille_logsdir}/${NEWNAME}_console.log;|" "${JAIL_CONFIG}"
            sed -i '' "s|path = .*;|path = ${bastille_jailsdir}/${NEWNAME}/root;|" "${JAIL_CONFIG}"
            sed -i '' "s|mount.fstab = .*;|mount.fstab = ${bastille_jailsdir}/${NEWNAME}/fstab;|" "${JAIL_CONFIG}"
            sed -i '' "s|${TARGET} {|${NEWNAME} {|" "${JAIL_CONFIG}"
            sed -i '' "s|${IPX_ADDR} = .*;|${IPX_ADDR} = ${IP};|" "${JAIL_CONFIG}"
        fi
    fi

    if grep -qw "vnet;" "${JAIL_CONFIG}"; then
        update_jailconf_vnet
    fi
}

update_jailconf_vnet() {
    bastille_jail_rc_conf="${bastille_jailsdir}/${NEWNAME}/root/etc/rc.conf"

    # Determine number of containers and define an uniq_epair
    local list_jails_num="$(bastille list jails | wc -l | awk '{print $1}')"
    local num_range="$(expr "${list_jails_num}" + 1)"
    jail_list=$(bastille list jail)
    for _num in $(seq 0 "${num_range}"); do
        if [ -n "${jail_list}" ]; then
            if ! grep -q "e0b_bastille${_num}" "${bastille_jailsdir}"/*/jail.conf; then
                if ! grep -q "epair${_num}" "${bastille_jailsdir}"/*/jail.conf; then
                    local uniq_epair="bastille${_num}"
                    local uniq_epair_bridge="${_num}"
	            # since we don't have access to the external_interface variable, we cat the jail.conf file to retrieve the mac prefix
                    # we also do not use the main generate_static_mac function here
                    local macaddr_prefix="$(cat ${JAIL_CONFIG} | grep -m 1 ether | grep -oE '([0-9a-f]{2}(:[0-9a-f]{2}){5})' | awk -F: '{print $1":"$2":"$3}')"
    	            local macaddr_suffix="$(echo -n ${NEWNAME} | sha256 | cut -b -5 | sed 's/\([0-9a-fA-F][0-9a-fA-F]\)\([0-9a-fA-F][0-9a-fA-F]\)\([0-9a-fA-F]\)/\1:\2:\3/')"
                    local macaddr="${macaddr_prefix}:${macaddr_suffix}"
	            # Update the exec.* with uniq_epair when cloning jails.
                    # for VNET jails
                    sed -i '' "s|bastille\([0-9]\{1,\}\)|${uniq_epair}|g" "${JAIL_CONFIG}"
                    sed -i '' "s|e\([0-9]\{1,\}\)a_${NEWNAME}|e${uniq_epair_bridge}a_${NEWNAME}|g" "${JAIL_CONFIG}"
                    sed -i '' "s|e\([0-9]\{1,\}\)b_${NEWNAME}|e${uniq_epair_bridge}b_${NEWNAME}|g" "${JAIL_CONFIG}"
                    sed -i '' "s|epair\([0-9]\{1,\}\)|epair${uniq_epair_bridge}|g" "${JAIL_CONFIG}"
		    sed -i '' "s|exec.prestart += \"ifconfig e0a_bastille\([0-9]\{1,\}\).*description.*|exec.prestart += \"ifconfig e0a_${uniq_epair} description \\\\\"vnet host interface for Bastille jail ${NEWNAME}\\\\\"\";|" "${JAIL_CONFIG}"
                    sed -i '' "s|ether.*:.*:.*:.*:.*:.*a\";|ether ${macaddr}a\";|" "${JAIL_CONFIG}"
                    sed -i '' "s|ether.*:.*:.*:.*:.*:.*b\";|ether ${macaddr}b\";|" "${JAIL_CONFIG}"
                    break
                fi
            fi
        fi
    done

    # Rename interface to new uniq_epair
    sed -i '' "s|ifconfig_e0b_bastille.*_name|ifconfig_e0b_${uniq_epair}_name|" "${bastille_jail_rc_conf}"
    sed -i '' "s|ifconfig_e.*b_${TARGET}_name|ifconfig_e${uniq_epair_bridge}b_${NEWNAME}_name|" "${bastille_jail_rc_conf}"
    
    # If 0.0.0.0 set DHCP, else set static IP address
    if [ "${IP}" = "0.0.0.0" ]; then
        sysrc -f "${bastille_jail_rc_conf}" ifconfig_vnet0="SYNCDHCP"
    else
        sysrc -f "${bastille_jail_rc_conf}" ifconfig_vnet0="inet ${IP}"
    fi
}

update_fstab() {
    # Update fstab to use the new name
    FSTAB_CONFIG="${bastille_jailsdir}/${NEWNAME}/fstab"
    if [ -f "${FSTAB_CONFIG}" ]; then
        # Update additional fstab paths with new jail path
        sed -i '' "s|${bastille_jailsdir}/${TARGET}/root/|${bastille_jailsdir}/${NEWNAME}/root/|" "${FSTAB_CONFIG}"
    fi
}

clone_jail() {
    # Attempt container clone
    info "Attempting to clone '${TARGET}' to ${NEWNAME}..."
    if ! [ -d "${bastille_jailsdir}/${NEWNAME}" ]; then
        if checkyesno bastille_zfs_enable; then
            if [ -n "${bastille_zfs_zpool}" ]; then
                # Replicate the existing container
                DATE=$(date +%F-%H%M%S)
                zfs snapshot -r "${bastille_zfs_zpool}/${bastille_zfs_prefix}/jails/${TARGET}@bastille_clone_${DATE}"
                zfs send -R "${bastille_zfs_zpool}/${bastille_zfs_prefix}/jails/${TARGET}@bastille_clone_${DATE}" | zfs recv "${bastille_zfs_zpool}/${bastille_zfs_prefix}/jails/${NEWNAME}"

                # Cleanup source temporary snapshots
                zfs destroy "${bastille_zfs_zpool}/${bastille_zfs_prefix}/jails/${TARGET}/root@bastille_clone_${DATE}"
                zfs destroy "${bastille_zfs_zpool}/${bastille_zfs_prefix}/jails/${TARGET}@bastille_clone_${DATE}"

                # Cleanup target temporary snapshots
                zfs destroy "${bastille_zfs_zpool}/${bastille_zfs_prefix}/jails/${NEWNAME}/root@bastille_clone_${DATE}"
                zfs destroy "${bastille_zfs_zpool}/${bastille_zfs_prefix}/jails/${NEWNAME}@bastille_clone_${DATE}"
            fi
        else
            # Just clone the jail directory
            # Check if container is running
            if [ -n "$(/usr/sbin/jls name | awk "/^${TARGET}$/")" ]; then
                error_exit "${TARGET} is running. See 'bastille stop ${TARGET}'."
            fi

            # Perform container file copy(archive mode)
            cp -a "${bastille_jailsdir}/${TARGET}" "${bastille_jailsdir}/${NEWNAME}"
        fi
    else
        error_exit "${NEWNAME} already exists."
    fi

    # Generate jail configuration files
    update_jailconf
    update_fstab

    # Display the exist status
    if [ "$?" -ne 0 ]; then
        error_exit "An error has occurred while attempting to clone '${TARGET}'."
    else
        info "Cloned '${TARGET}' to '${NEWNAME}' successfully."
    fi
}

## don't allow for dots(.) in container names
if echo "${NEWNAME}" | grep -q "[.]"; then
    error_exit "Container names may not contain a dot(.)!"
fi

## check if ip address is valid
if [ -n "${IP}" ]; then
    validate_ip
else
    usage
fi

clone_jail
