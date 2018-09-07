#!/bin/bash

echo "Setting $1 access for groups in $2"
echo "Notifying $3"
cd /home/chris/gitlabwork/gitlab_tools
./setbulkaccess.pl $1 $2 | mailx -s "Setting $1 access for groups in $2" $3
