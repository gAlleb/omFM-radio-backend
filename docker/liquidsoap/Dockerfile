#FROM savonet/liquidsoap-alpine:v2.3.1

#FROM alpine:3.20 as downloader

#RUN set -eux; \
#      mkdir /packages; \
#      wget https://github.com/savonet/liquidsoap-release-assets/releases/download/v2.3.1/liquidsoap-x86_64-2.3.1-r0.apk -O /packages/liquidsoap.apk; 

#FROM alpine:latest



#FROM savonet/liquidsoap-ci-build:main_alpine_amd64
#FROM savonet/liquidsoap-alpine:rolling-release-v2.5.x
FROM savonet/liquidsoap-alpine:v2.4.5
#FROM savonet/liquidsoap-alpine:8310ee9

ARG USER_UID
ARG USER_GID

USER root

ENV TZ=UTC

RUN addgroup -g "${USER_GID}" radio && adduser -u "${USER_UID}" -G radio -S radio

#RUN  --mount=type=bind,target=/packages,source=/packages,from=downloader \
RUN   apk add --no-cache --allow-untrusted \
#      -X https://dl-cdn.alpinelinux.org/alpine/edge/testing \
#      /packages/liquidsoap.apk \
      ffmpeg \
      python3 \
      py3-mutagen \
      tzdata \
      curl \ 
      bash \
      ;

COPY ./docker/liquidsoap/rootfs /

RUN chmod +x /usr/bin/cue_file
RUN chmod +x /usr/bin/telegram-send-omfm


# playlog и song_history пишутся в <станция>/log. Каталог обязан существовать:
# без него check падает с ENOENT, плейлист не отдаёт ни одного трека и в эфир
# идут только джинглы. Git пустые каталоги не хранит, поэтому создаём здесь —
# автоматически для любой станции, включая будущие.
RUN for d in /home/radio/liquidsoap/*/; do \
      [ "$d" = "/home/radio/liquidsoap/lib/" ] || mkdir -p "$d/log"; \
    done

RUN chown -R radio:radio /home/radio 
# Одна станция — один контейнер, один процесс.
# Скрипт станции передаётся как command из docker-compose.yaml,
# он же генерируется из stations.toml.
USER radio

ENTRYPOINT [ "/usr/bin/liquidsoap" ]
