#!/bin/bash
sed -i "s#129#229#g" /usr/local/kcptun/server-config$1.json
supervisorctl restart kcptun$1
