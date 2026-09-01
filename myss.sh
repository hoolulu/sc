#!/bin/bash
at 00:00 2023-$1 << EOF
sed -i "s#$2#AAA$2#g" /root/v2ray/config.json
systemctl restart xray.service
EOF
