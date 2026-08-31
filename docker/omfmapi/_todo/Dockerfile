FROM node:20.17-alpine

RUN mkdir -p /home/node/app
RUN mkdir -p /home/node/app/db
RUN mkdir -p /home/node/app/playlist

COPY  ./docker/omfmapi/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /home/node/app

COPY ./docker/omfmapi/app/package*.json ./docker/omfmapi/app/server.js ./
COPY ./docker/omfmapi/hls_listeners_api.py .

# Ensure the node user can read the nginx log (www-data)
RUN adduser node www-data
RUN adduser node adm

RUN chown -R node:node /home/node/app

ENV TZ=UTC

RUN apk add --no-cache --allow-untrusted \
    python3 \  
    py3-pip \ 
    py3-requests \
    tzdata \
    acl \
    ;

RUN mkdir -p /var/log/nginx
RUN setfacl -m u:node:rX /var/log/nginx
RUN setfacl -d -m u:node:rX /var/log/nginx

USER node

RUN npm install

CMD ["/usr/local/bin/docker-entrypoint.sh"]

#CMD [ "npm", "start"]
