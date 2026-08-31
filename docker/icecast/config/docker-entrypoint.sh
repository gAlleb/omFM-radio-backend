#!/bin/sh

# Значения подставляются из окружения (см. .env в корне проекта).
# В icecast.xml лежат плейсхолдеры SET_VIA_ENV — стартовать с ними нельзя.
missing=''
for var in ICECAST_SOURCE_PASSWORD ICECAST_RELAY_PASSWORD ICECAST_ADMIN_PASSWORD ICECAST_ADMIN_USERNAME; do
  eval "val=\$$var"
  if [ -z "$val" ]; then
    missing="$missing $var"
  fi
done

if [ -n "$missing" ]; then
  echo "icecast: отказ запуска — не заданы обязательные переменные:$missing" >&2
  echo "icecast: проверь .env в корне проекта и секцию environment в docker-compose.yaml" >&2
  exit 1
fi

edit_icecast_config() {
  xml-edit "$@" /etc/icecast.xml
}

edit_icecast_config source-password "$ICECAST_SOURCE_PASSWORD"
edit_icecast_config relay-password "$ICECAST_RELAY_PASSWORD"
edit_icecast_config admin-password "$ICECAST_ADMIN_PASSWORD"
edit_icecast_config admin-user "$ICECAST_ADMIN_USERNAME"

if [ -n "$ICECAST_ADMIN_EMAIL" ]; then
  edit_icecast_config admin "$ICECAST_ADMIN_EMAIL"
fi
if [ -n "$ICECAST_LOCATION" ]; then
  edit_icecast_config location "$ICECAST_LOCATION"
fi
if [ -n "$ICECAST_HOSTNAME" ]; then
  edit_icecast_config hostname "$ICECAST_HOSTNAME"
fi
if [ -n "$ICECAST_MAX_CLIENTS" ]; then
  edit_icecast_config clients "$ICECAST_MAX_CLIENTS"
fi
if [ -n "$ICECAST_MAX_SOURCES" ]; then
  edit_icecast_config sources "$ICECAST_MAX_SOURCES"
fi

exec "$@"
