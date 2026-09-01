#!/bin/bash
at 00:00 2023-$1 << EOF
sed -i "s#299#199#g" /usr/local/kcptun/server-config$2.json
supervisorctl restart kcptun$2
EOF
