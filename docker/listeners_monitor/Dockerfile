FROM python:3.9-slim-buster
RUN mkdir /var/log/nginx
WORKDIR /app
COPY ./docker/listeners_monitor/hls_listeners_api.py .
RUN pip install --no-cache requests aiohttp
CMD [ "python", "hls_listeners_api.py" ]