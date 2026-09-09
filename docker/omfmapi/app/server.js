'use strict';

const fs = require('fs');
const express = require('express');
const axios = require('axios');
const https = require('https');
const { URLSearchParams } = require('url');

const app = express();
app.use(express.json({ limit: 52428800 }));
const server = require('http').createServer(app);

/////////////////////////////////
////////////КОНФИГУРАЦИЯ/////////
/////////////////////////////////

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`omfmapi: не задана обязательная переменная окружения ${name}`);
    console.error('omfmapi: проверь .env в корне проекта и секцию environment в docker-compose.yaml');
    process.exit(1);
  }
  return value;
}

const CENTRIFUGO_API_KEY = requireEnv('CENTRIFUGO_API_KEY');
const AZURACAST_API_KEY = requireEnv('AZURACAST_API_KEY');
const OMFMAPI_USER = requireEnv('OMFMAPI_USER');
const OMFMAPI_PASSWORD = requireEnv('OMFMAPI_PASSWORD');

const SPOTIFY_CLIENT_ID = requireEnv('SPOTIFY_CLIENT_ID');
const SPOTIFY_CLIENT_SECRET = requireEnv('SPOTIFY_CLIENT_SECRET');

const AZURACAST_BASE = process.env.AZURACAST_BASE || 'https://radio.omfm.ru';
const CENTRIFUGO_URL = process.env.CENTRIFUGO_URL || 'http://centrifugo:9998/api/publish';
const port = process.env.PORT || 9999;
const STATIONS_FILE = process.env.STATIONS_FILE || './stations.json';

// Реестр станций читается из сгенерированного stations.json —
// единственный источник правды это stations.toml в корне проекта.
// Порядок ключей значим: он задаёт порядок полей в ответе /listeners.
const REGISTRY = JSON.parse(fs.readFileSync(STATIONS_FILE, 'utf8'));
const STATIONS = REGISTRY.stations;

// Пиры — чужое радио на том же стеке. Их поток мы не вещаем и не
// ретранслируем, забираем только слушателей, чтобы они попадали в общую
// статистику. Ключи, под которыми они у нас появляются, gen-config.py
// уже проверил на совпадение с ключами своих станций.
const PEERS = REGISTRY.peers || {};
const PEER_KEYS = Object.values(PEERS).flatMap((peer) => Object.values(peer.stations));

// Только станции, участвующие в статистике слушателей.
const STATION_KEYS = Object.keys(STATIONS).filter((key) => STATIONS[key].monitor !== false);
const LOCAL_STATIONS = STATION_KEYS.filter((key) => STATIONS[key].kind === 'local');
// Релеи, у которых есть id на нашем AzuraCast — только с них тянем слушателей.
const RELAY_STATIONS = STATION_KEYS.filter(
  (key) => STATIONS[key].kind === 'relay' && STATIONS[key].azuracastId !== undefined
);

const centrifugoApiClient = axios.create({
  baseURL: CENTRIFUGO_URL,
  headers: {
    'X-API-key': CENTRIFUGO_API_KEY,
    'Content-Type': 'application/json',
  },
});

/////////////////////////////////
////////////СОСТОЯНИЕ////////////
/////////////////////////////////

// Последний np, присланный Liquidsoap: станция -> объект
const npData = new Map();
// song.text, на котором уже отправляли "track has changed": станция -> строка
const lastSongText = new Map();

// Слушатели от listeners_monitor (nginx HLS + icecast listclients)
const hlsListeners = {};
// Слушатели от AzuraCast API
const apiListeners = {};
for (const key of STATION_KEYS) {
  hlsListeners[key] = [];
  apiListeners[key] = [];
}

/////////////////////////////////
//////////СЛУШАТЕЛИ//////////////
/////////////////////////////////

async function fetchListenerData() {
  const results = await Promise.allSettled(
    RELAY_STATIONS.map(async (key) => {
      const url = `${AZURACAST_BASE}/api/station/${STATIONS[key].azuracastId}/listeners`;
      const response = await axios.get(url, {
        headers: { 'X-API-KEY': AZURACAST_API_KEY },
      });
      return { key, listeners: response.data };
    })
  );

  // Каждая станция обрабатывается независимо: падение одной не должно
  // оставлять остальные с устаревшими данными.
  results.forEach((result, index) => {
    if (result.status === 'fulfilled') {
      const { key, listeners } = result.value;
      apiListeners[key] = listeners.map((listener) => ({
        ...listener,
        source: 'AzuraCast API',
        stream: key,
      }));
    } else {
      console.error(
        `Ошибка получения слушателей AzuraCast для станции ${RELAY_STATIONS[index]}:`,
        result.reason.message
      );
    }
  });
}

fetchListenerData();
setInterval(fetchListenerData, 30000);

// Пир опрашивается по HTTP: он отдаёт /api/listeners ровно в том же
// формате, что и мы, — total_listeners плюс список записей на станцию.
const PEER_POLL_MS = 30000;
// Три пропущенных опроса подряд — считаем, что связи нет. Замёрзшие
// числа хуже отсутствующих: по ним не видно, что пир недоступен.
const PEER_TTL_MS = PEER_POLL_MS * 3;

// наш ключ станции -> { listeners: [...], at: время последнего успешного ответа }
const peerListeners = {};

async function fetchPeerListeners() {
  const peers = Object.entries(PEERS);
  if (peers.length === 0) {
    return;
  }

  const results = await Promise.allSettled(
    peers.map(([, peer]) => axios.get(peer.url, { timeout: 10000 }))
  );

  results.forEach((result, index) => {
    const [name, peer] = peers[index];

    if (result.status !== 'fulfilled') {
      console.error(`Ошибка получения слушателей пира ${name}:`, result.reason.message);
      return;
    }

    const data = result.value.data;
    const now = Date.now();

    for (const [their, ours] of Object.entries(peer.stations)) {
      const listeners = data[their];
      if (!Array.isArray(listeners)) {
        console.error(`Пир ${name}: в ответе нет списка станции ${their}`);
        continue;
      }

      // Записи берём целиком. Своё поле source не затираем — у пира это
      // тот же HLS-монитор, — а происхождение помечаем отдельно.
      peerListeners[ours] = {
        at: now,
        listeners: listeners.map((listener) => ({ ...listener, peer: name, stream: ours })),
      };
    }
  });
}

fetchPeerListeners();
setInterval(fetchPeerListeners, PEER_POLL_MS);

// Сводка по всем станциям: списки слушателей из обоих источников + счётчики.
function buildListenersPayload() {
  const combined = {};
  const totalListeners = {};

  for (const key of STATION_KEYS) {
    combined[key] = [...hlsListeners[key], ...apiListeners[key]];
    totalListeners[key] = combined[key].length;
  }

  // Свои станции заполняются первыми, пиры добавляются следом. На порядок
  // полей в ответе при этом полагаться нельзя: числовой ключ вроде "386"
  // JS всё равно поднимет в начало объекта.
  const stale = Date.now() - PEER_TTL_MS;
  for (const key of PEER_KEYS) {
    const entry = peerListeners[key];
    if (!entry || entry.at < stale) {
      continue;
    }
    combined[key] = entry.listeners;
    totalListeners[key] = entry.listeners.length;
  }

  return { total_listeners: totalListeners, ...combined };
}

/////////////////////////////////
///////////SPOTIFY///////////////
/////////////////////////////////

let spotifyToken = '';

async function getSpotifyToken() {
  try {
    const authOptions = {
      hostname: 'accounts.spotify.com',
      path: '/api/token',
      method: 'POST',
      headers: {
        'Authorization':
          'Basic ' + Buffer.from(`${SPOTIFY_CLIENT_ID}:${SPOTIFY_CLIENT_SECRET}`).toString('base64'),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    };

    const data = new URLSearchParams();
    data.append('grant_type', 'client_credentials');

    const req = https.request(authOptions, (res) => {
      let data = '';
      res.on('data', (chunk) => {
        data += chunk;
      });

      res.on('end', () => {
        const body = JSON.parse(data);
        if (res.statusCode === 200) {
          spotifyToken = body.access_token;
        } else {
          console.error(`Error fetching token: ${res.statusCode} - ${body.error}`);
        }
      });
    });

    req.on('error', (error) => {
      console.error(`Error during request: ${error.message}`);
    });

    req.write(data.toString());
    req.end();
  } catch (e) {
    console.error(e.message);
  }
}

getSpotifyToken();
setInterval(getSpotifyToken, 1800000);

/////////////////////////////////
////////ПУБЛИЧНЫЕ РОУТЫ//////////
/////////////////////////////////

app.get('/spotifyToken', (req, res) => {
  res.send(spotifyToken);
});

app.get('/np', (req, res) => {
  res.json(
    LOCAL_STATIONS.map((key) => ({
      channel: `station:${STATIONS[key].shortcode}`,
      data: { np: npData.get(key), spotifyToken },
    }))
  );
});

app.get('/listeners', (req, res) => {
  res.json(buildListenersPayload());
});

/////////////////////////////////
////////АВТОРИЗАЦИЯ//////////////
/////////////////////////////////

// Всё, что зарегистрировано ниже, требует HTTP Basic.
function authentication(req, res, next) {
  const authheader = req.headers.authorization;

  if (!authheader || !authheader.startsWith('Basic ')) {
    res.set('WWW-Authenticate', 'Basic realm="omfmapi"');
    return res.sendStatus(401);
  }

  try {
    const [user, pass] = Buffer.from(authheader.split(' ')[1], 'base64').toString().split(':');
    if (user === OMFMAPI_USER && pass === OMFMAPI_PASSWORD) {
      return next();
    }
  } catch (e) {
    console.error(e.message);
  }

  res.set('WWW-Authenticate', 'Basic realm="omfmapi"');
  return res.sendStatus(401);
}

app.use(authentication);

/////////////////////////////////
/////ЗАЩИЩЁННЫЕ РОУТЫ////////////
/////////////////////////////////

app.post('/listeners_stat', (req, res) => {
  const dataFromHlsStat = req.body;

  for (const streamName in dataFromHlsStat) {
    if (streamName !== 'total_listeners' && streamName in hlsListeners) {
      hlsListeners[streamName] = dataFromHlsStat[streamName].map((listener) => ({
        ...listener,
        source: 'Python HLS/Icecast Monitor',
      }));
    }
  }

  res.sendStatus(200);
});

function acceptNowPlaying(key, body) {
  npData.set(key, body);
  publishOnTrackChange(key);
}

app.post('/np/:station', (req, res) => {
  const key = req.params.station;

  if (!STATIONS[key] || STATIONS[key].kind !== 'local') {
    return res.status(404).json({ error: `unknown local station: ${key}` });
  }

  acceptNowPlaying(key, req.body);
  res.sendStatus(200);
});

/////////////////////////////////
////////////CENTRIFUGO///////////
/////////////////////////////////

async function publishStation(key, extra = {}) {
  try {
    await centrifugoApiClient.post('', {
      channel: `station:${STATIONS[key].shortcode}`,
      data: { np: npData.get(key), spotifyToken, ...extra },
    });
  } catch (e) {
    console.error(e.message);
  }
}

async function publishOnTrackChange(key) {
  const np = npData.get(key);

  try {
    if (np.now_playing.song.text !== null && np.now_playing.song.text !== lastSongText.get(key)) {
      await publishStation(key, { trigger: 'track has changed' });
      lastSongText.set(key, np.now_playing.song.text);
    }
  } catch (e) {
    console.error(e);
  }
}

async function publishListeners() {
  try {
    await centrifugoApiClient.post('', {
      channel: 'station:listeners',
      data: buildListenersPayload(),
    });
  } catch (e) {
    console.error(e.message);
  }
}

setInterval(() => {
  for (const key of LOCAL_STATIONS) {
    publishStation(key);
  }
  publishListeners();
}, 15000);

/////////////////////////////////
/////////////////////////////////
/////////////////////////////////

server.listen(port, () => console.log(`Listening on ${port}`));
