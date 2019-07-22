#!/bin/bash

if [ ! -z ${DEBUG} ];then
    set -x
fi

# get input parameter, the sbwdn server address
SBWPI_DIR=`pwd`

while true;
do
    read -p "Please input the sbwdn server address:" SBWDN_SERVER
    if [ ! -z $SBWDN_SERVER ];then
        break
    fi
done

echo "Allow access router from outside?"
select yn in "Yes" "No"; do
    case $yn in
        Yes ) ALLOW_WAN_INPUT=yes; break;;
        No ) break;;
    esac
done

which iptables-legacy
if [ $? == 0 ];then
    echo "iptables-legacy exists, use it"
    IPTABLES=iptables-legacy
else
    IPTABLES=iptables
fi

check_cur_dir() {
    if [ ! -e sbwpi.sh ];then
        echo "please run this script inside sbwpi dir, e.g: cd sbwpi;./sbwpi.sh" >&2
        exit 1
    fi

    return 0
}
# use aliyun mirror
setup_mirror() {
    echo "using aliyun mirror"
    VERSION_CODENAME=$(cat /etc/os-release |grep VERSION_CODENAME |cut -d= -f 2)
    echo "deb http://mirrors.aliyun.com/raspbian/raspbian/ ${VERSION_CODENAME} main contrib non-free rpi" > /etc/apt/sources.list || return 1

    return 0
}

# install softwares
install_softwares() {
    apt update && apt -y install hostapd dnsmasq git gcc libevent-dev libconfuse-dev netfilter-persistent python-flask || return 1

    return 0
}

# setup udev, internal is wlan0, usb wifi is wlan1
setup_udev() {
    echo "setting up udev rules so that internal wifi will be wlan0 as ap, usb wifi douge will be wlan1"
    # find internal wlan mac
    for ((i=0; i<3; i++));
    do
        ip link show wlan$i
        if [ $? == 0 ];then
            ip link show wlan$i | grep 'link/ether dc:26:32'
            OUI_4=$?
            ip link show wlan$i | grep 'link/ether b8:27:eb'
            OUI_3=$?
            if [[ $OUI_4 == 0 || $OUI_3 == 0 ]];then
                WLAN0_MAC=$(ip link show wlan$i | grep 'link/ether' | sed 's/  */,/g' | cut -d ',' -f 3)
                break
            fi
        fi
    done

    if [ -z $WLAN0_MAC ];then
        echo "failed to find mac addr for internal wifi interface" >&2
        return 1
    fi

    rm -f /etc/udev/rules.d/72-sbwpi-static-wlan-name.rules || return 1
    echo 'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="'${WLAN0_MAC}'", KERNEL=="wl*", NAME="wlan0"' >> /etc/udev/rules.d/72-sbwpi-static-wlan-name.rules || return 1
    echo 'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}!="'${WLAN0_MAC}'", KERNEL=="wl*", NAME="wlan1"' >> /etc/udev/rules.d/72-sbwpi-static-wlan-name.rules || return 1

    return 0
}

# setup ap
setup_ap() {
    echo "setting up access point"
    systemctl stop hostapd
    systemctl stop dnsmasq

    cat /etc/dhcpcd.conf | grep '^#sbwdn change'
    if [ $? == 0 ];then
        echo "looks like dhcpcd.conf has already been updated, will ignore..."
    else
        cat dhcpcd.conf.add >> /etc/dhcpcd.conf || return 1
    fi

    cp dnsmasq.sbwdn.conf /etc/dnsmasq.d/dnsmasq.sbwdn.conf || return 1

    cp hostapd.conf /etc/hostapd/hostapd.conf || return 1

    cp wlan0 /etc/network/interfaces.d/wlan0 || return 1

    systemctl unmask hostapd || return 1
    systemctl enable hostapd || return 1
    systemctl enable dnsmasq || return 1

    return 0
}

setup_wlan1() {
    echo "creating configure for wlan1"
    cp wlan1 /etc/network/interfaces.d/wlan1 || return 1
    cp wpa_supplicant-wlan1.conf /etc/wpa_supplicant/wpa_supplicant-wlan1.conf || return 1

    return 0
}

# build sbwdn
build_sbwdn() {
    echo "building sbwdn"
    if [ -d sbwdn/src ];then
        (cd sbwdn/src && git fetch && git pull ) || return 1
    else
        git clone https://github.com/sevenever/sbwdn.git sbwdn/src || return 1
    fi

    make -C sbwdn/src clean && make -C sbwdn/src && rm -f sbwdn/sbwdn && cp sbwdn/src/sbwdn sbwdn/sbwdn || return 1

    return 0
}

# config sbwdn
config_sbwdn() {
    echo "confiureing sbwdn"
    echo "mode=client" > $SBWPI_DIR/sbwdn/client.conf
    echo "remote=$SBWDN_SERVER" >>$SBWPI_DIR/sbwdn/client.conf

    cp if_up_script $SBWPI_DIR/sbwdn/if_up_script || return 1
    cp if_down_script $SBWPI_DIR/sbwdn/if_down_script || return 1
    chmod 755 $SBWPI_DIR/sbwdn/if_up_script || return 1
    chmod 755 $SBWPI_DIR/sbwdn/if_down_script || return 1

    return 0
}

# launch sbwdn
launch_sbwdn() {
    kill $(cat /var/run/sbwdn.pid)
    sbwdn/sbwdn -f sbwdn/client.conf || return 1

    return 0
}

# setup pskmgr

# setup dnsmasq
setup_dnsmasq() {
    echo "setting up dnsmasq to use gfw list"
    cp my.list /etc/dnsmasq.d/my.list || return 1
    cp gfw.list /etc/dnsmasq.d/gfw.list || return 1

    systemctl restart dnsmasq || return 1

    return 0
}

# setup crontab for updategfwlist
setup_crontab() {
    echo "setting up crontab to refresh gfw list every day"
    crontab -l | grep updategfwlist
    if [ $? == 0 ];then
        echo "looks like crontab has already been updated, will ignore..."
    else
        (crontab -l ; echo "00 03 * * * $SBWPI_DIR/updategfwlist") | crontab - || return 1
    fi

    return 0
}

# set up sbwdn.service
setup_service() {
    echo "setting up systemd service to launch pskmgr when reboot"

    cat sbwdn.service | sed "s~SBWPI_DIR~$SBWPI_DIR~g" > /etc/systemd/system/sbwdn.service || return 1
    cat sbwdnservice | sed "s~SBWPI_DIR~$SBWPI_DIR~g" > sbwdnservice.tmp
    mv sbwdnservice.tmp sbwdnservice
    chmod 755 sbwdnservice

    systemctl enable sbwdn.service || return 1

    return 0
}

# setup firewall
setup_firewall() {
    echo "setting up firewall to allow ip forward and MASQUERADE"
    sysctl net.ipv4.ip_forward=1 >> /etc/sysctl.conf || return 1

    $IPTABLES -t nat -A POSTROUTING -o wlan1 -j MASQUERADE
    $IPTABLES -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    $IPTABLES -t nat -A POSTROUTING -o sbwdn -j MASQUERADE

    $IPTABLES -t mangle -A FORWARD -o wlan1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    $IPTABLES -t mangle -A FORWARD -o eth0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    $IPTABLES -t mangle -A FORWARD -o sbwdn -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    $IPTABLES -t filter -P FORWARD DROP
    $IPTABLES -t filter -I FORWARD -s 192.168.4.0/24 -j ACCEPT
    $IPTABLES -t filter -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    $IPTABLES -t filter -P INPUT DROP
    $IPTABLES -t filter -A INPUT -i lo -j ACCEPT
    $IPTABLES -t filter -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    $IPTABLES -t filter -A INPUT -p icmp -m icmp --icmp-type 8 -j ACCEPT
    $IPTABLES -t filter -A INPUT -p udp --dport 53 -s 192.168.4.1/24 -j ACCEPT
    $IPTABLES -t filter -A INPUT -p tcp --dport 22 -s 192.168.4.1/24 -j ACCEPT
    $IPTABLES -t filter -A INPUT -p tcp --dport 80 -s 192.168.4.1/24 -j ACCEPT
    $IPTABLES -t filter -A INPUT -p udp --dport 67 -i wlan0 -j ACCEPT
    if [ ! -z $ALLOW_WAN_INPUT ];then
        $IPTABLES -t filter -A INPUT -i eth0 -j ACCEPT
        $IPTABLES -t filter -A INPUT -i wlan1 -j ACCEPT
    fi


    $IPTABLES-save > iptables.rule

    return 0
}

check_cur_dir || exit 1
setup_mirror || exit 1
install_softwares || exit 1
setup_udev || exit 1
setup_ap || exit 1
setup_wlan1 || exit 1
build_sbwdn || exit 1
config_sbwdn || exit 1
launch_sbwdn || exit 1
setup_dnsmasq || exit 1
setup_crontab || exit 1
setup_service || exit 1
setup_firewall || exit 1

echo "Successfully setup pi for sbwdn"

exit 0
