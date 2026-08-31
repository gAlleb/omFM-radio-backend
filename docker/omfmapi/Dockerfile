FROM node:24-alpine

RUN mkdir -p /home/node/app

WORKDIR /home/node/app

COPY ./docker/omfmapi/app/package*.json ./docker/omfmapi/app/server.js ./

RUN chown -R node:node /home/node/app

ENV TZ=UTC

RUN apk add --no-cache --allow-untrusted \
    tzdata \
    ;

USER node

RUN npm install

CMD [ "npm", "start"]
