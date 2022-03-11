#!/bin/bash
#
# $1 site dir

cd $1
source .env
[[ ! -d $1/dbdump ]] && mkdir $1/dbdump

# dev
#/home/ubuntu/.local/bin/docker-compose exec -T db mysqldump -u $WORDPRESS_DB_USER -p$WORDPRESS_DB_PASSWORD $WORDPRESS_DB_NAME 2>>/tmp/tmplog3 | xz > $1/dbdump/dbdump-wp-$(date +%F-%H:%M).sql.xz 2>>/tmp/tmplog4

#prod
/home/ubuntu/.local/bin/docker-compose exec -T db mysqldump -u $WORDPRESS_DB_USER -p$WORDPRESS_DB_PASSWORD $WORDPRESS_DB_NAME | xz > $1/dbdump/dbdump-wp-$(date +%F-%H:%M).sql.xz
