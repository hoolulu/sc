#!/bin/bash
ps -ef | grep supervisord | grep -v grep
if [ $? -ne 0 ]
then
echo "start supervisord......"
service supervisord restart
else
echo "supervisord runing......"
fi
