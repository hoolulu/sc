#!/bin/bash
ps -ef | grep socks5 | grep -v grep
if [ $? -ne 0 ]
then
echo "start process......"
/etc/init.d/kcp-server restart
else
echo "runing......"
fi