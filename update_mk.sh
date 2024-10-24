#!/bin/bash
# Copyright 2024 Oliver Brunovsky

if [ -f /home/brunovsky/up_ac_ax_mk/.env ]; then
  export $(grep -v '^#' .env | xargs)
fi

switches=$(</home/brunovsky/up_ac_ax_mk/switches.txt)
USERNAME="technik"
WIFI_CHANNEL_2GHZ="2412,2432,2472"
WIFI_CHANNEL_5GHZ="5180,5260,5500"
#NMAP_TIMEOUT=5

log_date=$(date +"%Y_%m_%d_%H_%M_%S")
log_dir="/home/brunovsky/up_ac_ax_mk/logs/$log_date"
mkdir $log_dir
log_file="$log_dir/switches.txt"
not_conn="$log_dir/not_connected.txt"
success="$log_dir/success.txt"
echo "$switches" >> "$log_file"

is_5ghz_interface() {
    local channel_width="$1"
    if [[ $channel_width == *"80"* ]]; then
        echo "true"
    else
        echo "false"
    fi
}

is_5ghz_band() {
    local band="$1"
    if [[ "$band" == *"5ghz"* || "$band" == *"ax"* ]]; then
        echo "true"
    else
        echo "false"
    fi
}

success_count=0

for switch_ip in $switches; do
    if [ "$success_count" -ge 40 ]; then
        echo "updatnutych 40 mikrotikov, vypinam"
        break
    fi

    nmap -p 8291 "$switch_ip" | grep -q "open"
    if [ $? -ne 0 ]; then
        echo "port 8291 nie je otvoreny $switch_ip"
        echo "$switch_ip" >> "$not_conn"
        continue
    fi

    nc -z -w5 $switch_ip 22
    if [ $? -ne 0 ]; then
        echo "timed out $switch_ip"
	echo "$switch_ip" >> "$not_conn"
        continue
    fi
    ssh-keygen -R "$switch_ip" 2>/dev/null
    ssh-keyscan -H "$switch_ip" >> ~/.ssh/known_hosts 2>/dev/null

    SSH_OUTPUT=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/system resource print
EOF
)

    BOARD_NAME=$(echo "$SSH_OUTPUT" | grep "board-name: " | sed 's/board-name: //')
    VERSION=$(echo "$SSH_OUTPUT" | grep "version: " | sed 's/version: //' | awk '{print $1}') 
    VERSION=$(echo "$VERSION" | xargs)
    if [[ "$VERSION" == "7.15.2" ]]; then
        echo "preskakujeme $switch_ip, verzia je 7.15.2"
        continue
    fi

    
    if [[ "$BOARD_NAME" == *"hAP ac^2"* ]]; then
        ARCHITECTURE="arm"
        ROS_PACKAGE_URL="https://download.mikrotik.com/routeros/7.15.2/routeros-7.15.2-arm.npk"
        ROS_PACKAGE_WIFI_URL="https://raw.githubusercontent.com/brunovskyoliver/mikrotik_update/main/wifi-qcom-ac-7.15.2-arm.npk"
        ROS_PACKAGE_NAME="routeros-7.15.2-arm.npk"
        ROS_PACKAGE_NAME_WIFI="wifi-qcom-ac-7.15.2-arm.npk"
    elif [[ "$BOARD_NAME" == *"hAP ax^2"* ]]; then
        ARCHITECTURE="arm64"
        ROS_PACKAGE_URL="https://download.mikrotik.com/routeros/7.15.2/routeros-7.15.2-arm64.npk"
        ROS_PACKAGE_WIFI_URL="https://raw.githubusercontent.com/brunovskyoliver/mikrotik_update/main/wifi-qcom-7.15.2-arm64.npk"
        ROS_PACKAGE_NAME="routeros-7.15.2-arm64.npk"
        ROS_PACKAGE_NAME_WIFI="wifi-qcom-7.15.2-arm64.npk"
    else
        echo "nepozna model: $BOARD_NAME"
        continue
    fi

    echo "model: $BOARD_NAME, arch: $ARCHITECTURE"

    SSH_OUTPUT=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wireless print detail
/interface wireless security-profiles print
EOF
)

    if [ "$ARCHITECTURE" == "arm" ]; then
        WLAN1_SECTION=$(echo "$SSH_OUTPUT" | awk '/^ 0 /, /^ 1 / { print }')
        SSIDS_WLAN1=$(echo "$WLAN1_SECTION" | grep -o 'ssid="[^"]*"' | cut -d '"' -f 2)
        CHANNEL_WIDTH_WLAN1=$(echo "$WLAN1_SECTION" | grep -o 'channel-width=[^ ]*' | cut -d '=' -f 2)
        IS_5GHZ_WLAN1=$(is_5ghz_interface "$CHANNEL_WIDTH_WLAN1")

        WLAN2_SECTION=$(echo "$SSH_OUTPUT" | awk '/^ 1 /, /^$/ { print }')
        SSIDS_WLAN2=$(echo "$WLAN2_SECTION" | grep -o 'ssid="[^"]*"' | cut -d '"' -f 2)
        CHANNEL_WIDTH_WLAN2=$(echo "$WLAN2_SECTION" | grep -o 'channel-width=[^ ]*' | cut -d '=' -f 2)
        IS_5GHZ_WLAN2=$(is_5ghz_interface "$CHANNEL_WIDTH_WLAN2")

        PASSPHRASE=$(echo "$SSH_OUTPUT" | grep -o 'wpa2-pre-shared-key="[^"]*"' | cut -d '"' -f 2)

        echo "SSIDs and Passphrase:"
        echo "Interface: wlan1, Band: $(if [[ "$IS_5GHZ_WLAN1" == "true" ]]; then echo "5GHz"; else echo "2.4GHz"; fi)"
        echo "$SSIDS_WLAN1" | while IFS= read -r ssid
        do
            echo "SSID: $ssid, Passphrase: $PASSPHRASE"
        done

        echo "Interface: wlan2, Band: $(if [[ "$IS_5GHZ_WLAN2" == "true" ]]; then echo "5GHz"; else echo "2.4GHz"; fi)"
        echo "$SSIDS_WLAN2" | while IFS= read -r ssid
        do
            echo "SSID: $ssid, Passphrase: $PASSPHRASE"
        done

        echo "stahuje na $switch_ip"
        sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/tool fetch url="$ROS_PACKAGE_URL" dst-path="$ROS_PACKAGE_NAME"
/tool fetch url="$ROS_PACKAGE_WIFI_URL" dst-path="$ROS_PACKAGE_NAME_WIFI"
/system package disable wifiwave2
/system reboot
EOF

        sleep 200

        echo "conf $switch_ip"
	    echo "$switch_ip" >> "$success"
        ((success_count++))
        if [[ "$IS_5GHZ_WLAN1" == "true" ]]; then
            SSID_WIFI1=$(echo "$SSIDS_WLAN1" | head -n 1)
            sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wifi channel add frequency="$WIFI_CHANNEL_5GHZ" name=ch-5ghz_7.15.2 width=20/40/80mhz band=5ghz-ac
/interface wifi security add name=auth_wifi1 authentication-types=wpa2-psk,wpa3-psk passphrase="$PASSPHRASE" wps=disable
/interface wifi configuration add channel.skip-dfs-channels=all country="United States Minor Outlying Islands" disabled=no name=conf_wifi1_7.15.2 security=auth_wifi1 ssid="$SSID_WIFI1"
/interface wifi set [ find default-name=wifi1 ] channel=ch-5ghz_7.15.2 configuration=conf_wifi1_7.15.2 disabled=no
/interface/bridge/port add interface=wifi1 bridge=Internal
/interface/bridge/port add interface=wifi2 bridge=Internal
/interface/bridge/port add interface=wifi1 bridge=LAN
/interface/bridge/port add interface=wifi2 bridge=LAN
EOF
        else
            SSID_WIFI1=$(echo "$SSIDS_WLAN1" | head -n 1)
            sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wifi channel add frequency="$WIFI_CHANNEL_2GHZ" name=ch-2ghz_7.15.2 width=20mhz band=2ghz-n
/interface wifi security add name=auth_wifi1 authentication-types=wpa2-psk,wpa3-psk passphrase="$PASSPHRASE" wps=disable
/interface wifi configuration add channel.skip-dfs-channels=all country="United States Minor Outlying Islands" disabled=no name=conf_wifi1_7.15.2 security=auth_wifi1 ssid="$SSID_WIFI1"
/interface wifi set [ find default-name=wifi1 ] channel=ch-2ghz_7.15.2 configuration=conf_wifi1_7.15.2 disabled=no
/interface/bridge/port add interface=wifi1 bridge=Internal
/interface/bridge/port add interface=wifi2 bridge=Internal
/interface/bridge/port add interface=wifi1 bridge=LAN
/interface/bridge/port add interface=wifi2 bridge=LAN
EOF
        fi

        if [[ "$IS_5GHZ_WLAN2" == "true" ]]; then
            SSID_WIFI2=$(echo "$SSIDS_WLAN2" | head -n 1)
            sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wifi channel add frequency="$WIFI_CHANNEL_5GHZ" name=ch-5ghz_7.15.2 width=20/40/80mhz band=5ghz-ac
/interface wifi security add name=auth_wifi2 authentication-types=wpa2-psk,wpa3-psk passphrase="$PASSPHRASE" wps=disable
/interface wifi configuration add channel.skip-dfs-channels=all country="United States Minor Outlying Islands" disabled=no name=conf_wifi2_7.15.2 security=auth_wifi2 ssid="$SSID_WIFI2"
/interface wifi set [ find default-name=wifi2 ] channel=ch-5ghz_7.15.2 configuration=conf_wifi2_7.15.2 disabled=no
/interface/bridge/port add interface=wifi1 bridge=Internal
/interface/bridge/port add interface=wifi2 bridge=Internal
/interface/bridge/port add interface=wifi1 bridge=LAN
/interface/bridge/port add interface=wifi2 bridge=LAN
EOF
        else
            SSID_WIFI2=$(echo "$SSIDS_WLAN2" | head -n 1)
            sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wifi channel add frequency="$WIFI_CHANNEL_2GHZ" name=ch-2ghz_7.15.2 width=20mhz band=2ghz-n
/interface wifi security add name=auth_wifi2 authentication-types=wpa2-psk,wpa3-psk passphrase="$PASSPHRASE" wps=disable
/interface wifi configuration add channel.skip-dfs-channels=all country="United States Minor Outlying Islands" disabled=no name=conf_wifi2_7.15.2 security=auth_wifi2 ssid="$SSID_WIFI2"
/interface wifi set [ find default-name=wifi2 ] channel=ch-2ghz_7.15.2 configuration=conf_wifi2_7.15.2 disabled=no
/interface/bridge/port add interface=wifi1 bridge=Internal
/interface/bridge/port add interface=wifi2 bridge=Internal
/interface/bridge/port add interface=wifi1 bridge=LAN
/interface/bridge/port add interface=wifi2 bridge=LAN
EOF
        fi
    elif [ "$ARCHITECTURE" == "arm64" ]; then
        SSH_OUTPUT=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wifiwave2/actual-configuration print
EOF
        )
        SSID_WIFI1=$(echo "$SSH_OUTPUT" | grep -o 'ssid="[^"]*"' | head -n 1 | cut -d '"' -f 2)
        BAND_WIFI1=$(echo "$SSH_OUTPUT" | grep -o 'band=[^ ]*' | head -n 1 | cut -d '=' -f 2)
        IS_5GHZ_WIFI1=$(is_5ghz_band "$BAND_WIFI1")

        SSID_WIFI2=$(echo "$SSH_OUTPUT" | grep -o 'ssid="[^"]*"' | tail -n 1 | cut -d '"' -f 2)
        BAND_WIFI2=$(echo "$SSH_OUTPUT" | grep -o 'band=[^ ]*' | tail -n 1 | cut -d '=' -f 2)
        IS_5GHZ_WIFI2=$(is_5ghz_band "$BAND_WIFI2")
        PASSPHRASE=$(echo "$SSH_OUTPUT" | grep -o 'passphrase="[^"]*"' | head -n 1 | cut -d '"' -f 2)
        echo "Wifi1:"
        echo "SSID: $SSID_WIFI1"
        echo "Wifi2:"
        echo "SSID: $SSID_WIFI2"
        echo "Passphrase: $PASSPHRASE"
        echo "stahuje na $switch_ip"
        sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/tool fetch url="$ROS_PACKAGE_URL" dst-path="$ROS_PACKAGE_NAME"
/tool fetch url="$ROS_PACKAGE_WIFI_URL" dst-path="$ROS_PACKAGE_NAME_WIFI"
/system package disable wifiwave2
/system reboot
EOF

        sleep 50

        echo "conf $switch_ip"
        echo "$switch_ip" >> "$success"
        ((success_count++))
        if [[ "$IS_5GHZ_WIFI1" == "true" ]]; then
            sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wifi channel add frequency="$WIFI_CHANNEL_5GHZ" name=ch-5ghz_7.15.2 width=20/40/80mhz
/interface wifi security add name=auth_wifi1 authentication-types=wpa2-psk,wpa3-psk passphrase="$PASSPHRASE_WIFI1" wps=disable
/interface wifi configuration add antenna-gain=0 channel.skip-dfs-channels=all country="United States Minor Outlying Islands" disabled=no name=conf_wifi1_7.15.2 security=auth_wifi1 ssid="$SSID_WIFI1"
/interface wifi set [ find default-name=wifi1 ] channel=ch-5ghz_7.15.2 configuration=conf_wifi1_7.15.2 disabled=no
/interface/bridge/port add interface=wifi1 bridge=Internal
/interface/bridge/port add interface=wifi2 bridge=Internal
/interface/bridge/port add interface=wifi1 bridge=LAN
/interface/bridge/port add interface=wifi2 bridge=LAN
EOF
        else
            sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wifi channel add frequency="$WIFI_CHANNEL_5GHZ" name=ch-5ghz_7.15.2 width=20/40/80mhz
/interface wifi security add name=auth_wifi1 authentication-types=wpa2-psk,wpa3-psk passphrase="$PASSPHRASE_WIFI2" wps=disable
/interface wifi configuration add antenna-gain=0 channel.skip-dfs-channels=all country="United States Minor Outlying Islands" disabled=no name=conf_wifi1_7.15.2 security=auth_wifi1 ssid="$SSID_WIFI2"
/interface wifi set [ find default-name=wifi1 ] channel=ch-5ghz_7.15.2 configuration=conf_wifi1_7.15.2 disabled=no
/interface/bridge/port add interface=wifi1 bridge=Internal
/interface/bridge/port add interface=wifi2 bridge=Internal
/interface/bridge/port add interface=wifi1 bridge=LAN
/interface/bridge/port add interface=wifi2 bridge=LAN
EOF
        fi

        if [[ "$IS_5GHZ_WIFI2" == "false" ]]; then
            sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wifi channel add frequency="$WIFI_CHANNEL_2GHZ" name=ch-2ghz_7.15.2 width=20mhz
/interface wifi security add name=auth_wifi2 authentication-types=wpa2-psk,wpa3-psk passphrase="$PASSPHRASE_WIFI2" wps=disable
/interface wifi configuration add antenna-gain=0 channel.skip-dfs-channels=all country="United States Minor Outlying Islands" disabled=no name=conf_wifi2_7.15.2 security=auth_wifi2 ssid="$SSID_WIFI2"
/interface wifi set [ find default-name=wifi2 ] channel=ch-2ghz_7.15.2 configuration=conf_wifi2_7.15.2 disabled=no
/interface/bridge/port add interface=wifi1 bridge=Internal
/interface/bridge/port add interface=wifi2 bridge=Internal
/interface/bridge/port add interface=wifi1 bridge=LAN
/interface/bridge/port add interface=wifi2 bridge=LAN
EOF
        else
            sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$switch_ip" << EOF
/interface wifi channel add frequency="$WIFI_CHANNEL_2GHZ" name=ch-2ghz_7.15.2 width=20mhz
/interface wifi security add name=auth_wifi2 authentication-types=wpa2-psk,wpa3-psk passphrase="$PASSPHRASE_WIFI1" wps=disable
/interface wifi configuration add antenna-gain=0 channel.skip-dfs-channels=all country="United States Minor Outlying Islands" disabled=no name=conf_wifi2_7.15.2 security=auth_wifi2 ssid="$SSID_WIFI1"
/interface wifi set [ find default-name=wifi2 ] channel=ch-2ghz_7.15.2 configuration=conf_wifi2_7.15.2 disabled=no
/interface/bridge/port add interface=wifi1 bridge=Internal
/interface/bridge/port add interface=wifi2 bridge=Internal
/interface/bridge/port add interface=wifi1 bridge=LAN
/interface/bridge/port add interface=wifi2 bridge=LAN
EOF
        fi
    else
        echo "Nepodporuje sa architektura: $ARCHITECTURE"
        continue
    fi
done
