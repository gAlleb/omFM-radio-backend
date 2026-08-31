FROM python:3.12-slim
RUN mkdir /var/log/nginx
WORKDIR /app
COPY ./docker/listeners_monitor/hls_listeners_api.py .
COPY ./docker/generated/stations.json .
RUN pip install --no-cache aiohttp
CMD [ "python", "hls_listeners_api.py" ]