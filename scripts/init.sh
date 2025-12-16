#!/bin/sh
docker events --filter 'event=start' --filter 'event=stop' --format '{{.Actor.Attributes.name}}' | /usr/local/bin/discover

exit $?