#!/bin/bash

echo "Setting $1 access for groups in $2"
cd /home/chris/gitlabwork/gitlab_tools
./setbulkaccess.pl $1 $2
