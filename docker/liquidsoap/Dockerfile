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
RUN mkdir -p /var/log/supervisor

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
      supervisor \
      ;

COPY ./docker/liquidsoap/rootfs /
COPY ./docker/liquidsoap/supervisord/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

RUN chmod +x /usr/bin/entrypoint
RUN chmod +x /usr/bin/docker-entrypoint
RUN chmod +x /usr/bin/cue_file
RUN chmod +x /usr/bin/telegram-send-omfm


RUN chown -R radio:radio /home/radio 
# Grant everyone write permissions on the supervisor logs
RUN chmod -R a+w /var/log/supervisor

USER root

ENTRYPOINT [ "docker-entrypoint" ]
