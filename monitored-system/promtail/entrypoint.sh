#!/bin/sh
exec /usr/bin/promtail --config.file=/etc/promtail/config.yml -config.expand-env=true
