.PHONY: help apply check secrets liq-check verify up down logs \
        station-deploy station-restart station-logs station-status

help:
	@echo "Стек omFM"
	@echo
	@echo "  make apply      сгенерировать конфиги из stations.toml"
	@echo "  make check      проверить, что конфиги не разъехались с реестром"
	@echo "  make secrets    пересобрать docker-секреты (*.txt) из .env"
	@echo "  make liq-check  проверить синтаксис всех .liq (liquidsoap --check)"
	@echo "  make verify     check + liq-check + валидация compose"
	@echo
	@echo "  make up / down / logs"
	@echo
	@echo "  Одна станция — один контейнер, поэтому их можно трогать по отдельности,"
	@echo "  не прерывая эфир остальных:"
	@echo "    make station-deploy  STATION=cdp   пересобрать и поднять только её"
	@echo "    make station-restart STATION=cdp"
	@echo "    make station-logs    STATION=cdp"
	@echo "    make station-status                состояние и healthcheck всех станций"

# Единственный источник правды — stations.toml. Всё остальное производно.
apply:
	@python3 tools/gen-config.py

check:
	@python3 tools/gen-config.py --check

# Docker-секреты дублировали значения из .env; теперь они из него и берутся.
secrets:
	@set -a; . ./.env; set +a; \
	printf '%s' "$$OMFMAPI_USER"            > docker/listeners_monitor/api_username.txt; \
	printf '%s' "$$OMFMAPI_PASSWORD"        > docker/listeners_monitor/api_password.txt; \
	printf '%s' "$$ICECAST_ADMIN_USERNAME"  > docker/listeners_monitor/icecast_username.txt; \
	printf '%s' "$$ICECAST_ADMIN_PASSWORD"  > docker/listeners_monitor/icecast_password.txt; \
	echo "секреты пересобраны из .env"

LIQ_IMAGE ?= savonet/liquidsoap-alpine:v2.4.5
LIQ_ROOT  := $(CURDIR)/docker/liquidsoap/rootfs/home/radio

# --check не нужны настоящие значения, но порты должны быть числами.
LIQ_ENV = -e STATION=$$st -e STATION_NAME=x -e STATION_SHORTCODE=x \
          -e STATION_TIMEZONE=Europe/Moscow -e STATION_MOUNT=/x \
          -e STATION_DESCRIPTION=x -e STATION_GENRE=x -e STATION_URL=x \
          -e HARBOR_PORT=8007 -e TELNET_PORT=1234 -e HLS_PLAYLIST=x.m3u8 \
          -e OMFMAPI_URL=http://omfmapi:9999/np/$$st \
          -e ICECAST_SOURCE_PASSWORD=x -e OMFMAPI_USER=x -e OMFMAPI_PASSWORD=x \
          -e LASTFM_API_KEY=x -e LASTFM_API_SECRET=x

liq-check:
	@rc=0; \
	for st in $$(python3 -c "import json;print(' '.join(k for k,v in json.load(open('docker/generated/stations.json'))['stations'].items() if v['kind']=='local'))"); do \
	  printf '  %-8s ' "$$st"; \
	  if docker run --rm -v "$(LIQ_ROOT):/home/radio:ro" $(LIQ_ENV) \
	      $(LIQ_IMAGE) liquidsoap --check /home/radio/liquidsoap/$$st/index.liq >/dev/null 2>&1; \
	  then echo "ok"; else echo "ОШИБКА"; rc=1; fi; \
	done; exit $$rc

verify: check liq-check
	@docker compose config >/dev/null && echo "  compose  ok"
	@node --check docker/omfmapi/app/server.js && echo "  server.js ok"
	@python3 -c "import ast;ast.parse(open('docker/listeners_monitor/hls_listeners_api.py').read())" \
	  && echo "  hls_listeners_api.py ok"

require-station:
	@test -n "$(STATION)" || { echo "укажи станцию: make $(MAKECMDGOALS) STATION=<имя>"; exit 1; }
	@python3 -c "import json,sys; \
	  st=json.load(open('docker/generated/stations.json'))['stations']; \
	  sys.exit(0) if st.get('$(STATION)',{}).get('kind')=='local' else \
	  (print('нет своей станции $(STATION); есть: '+', '.join(k for k,v in st.items() if v['kind']=='local')), sys.exit(1))"

# Пересобирает и поднимает ТОЛЬКО указанную станцию — эфир остальных не прерывается.
station-deploy: require-station check
	docker compose up -d --build liquidsoap-$(STATION)

station-restart: require-station
	docker compose restart liquidsoap-$(STATION)

station-logs: require-station
	docker compose logs -f --tail=200 liquidsoap-$(STATION)

station-status:
	@docker compose ps --format 'table {{.Service}}\t{{.Status}}' | command grep -E 'SERVICE|liquidsoap-'

up: check
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f --tail=100
