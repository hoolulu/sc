#!/bin/bash
at 00:00 2023-$1 << EOF
bash mytrojan.sh del $2
systemctl restart caddy.service
EOF
