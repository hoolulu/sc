#!/bin/bash
at 00:00 2024-$1 << EOF
sed -i "s#129#229#g" /usr/local/kcptun/server-config$2.json
supervisorctl restart kcptun$2
EOF
