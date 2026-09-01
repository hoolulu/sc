#!/bin/bash
sed -i "s#229#129#g" /usr/local/kcptun/server-config$1.json
supervisorctl restart kcptun$1
