const express = require('express');
const app = express();
app.use(express.json({limit : 52428800}));
const server = require('http').createServer(app);
const EventEmitter = require('events');
const eventEmitter = new EventEmitter();
eventEmitter.setMaxListeners(500);
const fs = require('fs');
let np, np_data, np_data_coma; 
let original_timestamp = 0;
const axios = require('axios');
const centrifugoApiClient = axios.create({
  baseURL: `http://centrifugo:9998/api/publish`,
  headers: {
    'X-API-key': 'hackme',
    'Content-Type': 'application/json',
  },
});

/////////////////////////////////
///////////SPOTIFY///////////////
/////////////////////////////////
///////////SPOTIFY///////////////
/////////////////////////////////
// DEPRECATED REQUEST
// var request = require('request');
// var client_id = 'hackme';
// var client_secret = 'hackme';
// var spotifyToken = '';

// async function getSpotifyToken() {
//   try {
// var authOptions = {
//   url: 'https://accounts.spotify.com/api/token',
//   headers: {
//     'Authorization': 'Basic ' + (new Buffer.from(client_id + ':' + client_secret).toString('base64'))
//   },
//   form: {
//     grant_type: 'client_credentials'
//   },
//   json: true
// };
// request.post(authOptions, function(error, response, body) {
//   if (!error && response.statusCode === 200) {
//     spotifyToken = body.access_token;
//     console.error(spotifyToken);
//   }
// });
//   } catch (e) {
//     console.error(e.message);
//   }
// }
// getSpotifyToken();
const https = require('https');
const { URLSearchParams } = require('url');

const client_id = 'hackme';
const client_secret = 'hackme';
let spotifyToken = '';

async function getSpotifyToken() {
  try {
    const authOptions = {
      hostname: 'accounts.spotify.com',
      path: '/api/token',
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + Buffer.from(`${client_id}:${client_secret}`).toString('base64'),
        'Content-Type': 'application/x-www-form-urlencoded'
      }
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
          console.log(spotifyToken);
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

const spotify_token_interval = setInterval(() => {
getSpotifyToken();
}, 1800000);

app.get('/spotifyToken', (req, res) => {
res.send(spotifyToken);
});

/////////////////////////////////
/////////////////////////////////
/////////////////////////////////

// Function to fetch playlist tracks from a remote URL
// async function importPlaylistFromUrl(url) {
//     try {
//         const response = await axios.get(url);
//         if (response.status === 200) {
//             const tracks = response.data.trim().split('\n');
//             return tracks;
//         } else {
//             console.error('Failed to fetch playlist from URL:', url);
//             return [];
//         }
//     } catch (error) {
//         console.error('Error fetching playlist from URL:', error);
//         return [];
//     }
// }


// RANDOM PLAYLIST SELECTION
// let playlist = []; // Initialize an empty array to store the playlist of tracks
// let playedTracks = []; // Initialize an empty array to store played tracks

// // Load the playlist of tracks into the server as an array
// app.post('/loadPlaylist', (req, res) => {
//     playlist = req.body.tracks; // Assuming the request body contains an array of tracks
//     res.json({ message: 'Playlist loaded successfully' });
// });

// // Get a random track from the playlist, remove it, and send it in the response
// app.get('/playTrack', (req, res) => {
//     if (playlist.length === 0) {
//         // If all tracks have been played, reload the playlist and reset the played tracks
//         playlist = [...playedTracks];
//         playedTracks = [];
//     }

//     const randomIndex = Math.floor(Math.random() * playlist.length);
//     const randomTrack = playlist[randomIndex];
//     playlist.splice(randomIndex, 1);
//     playedTracks.push(randomTrack);

//     res.json({ track: randomTrack });
// });


//Function to read the playlist file and return an array of track paths
const chokidar = require('chokidar');

let playlistTracks = [];
let numberOfTracks;
//let currentTrackIndex = getCurrentTrackIndex();
let lastRequestDate = new Date().toLocaleString().slice(0, 10); // YYYY-MM-DD
let currentTrack = {};
let currentTrack_saved = {};

function addConsumedFlagToTracks(tracks) {
    return tracks.map(track => {
        return {
            path: track,
            consumed: false,
            consumed2: false
        };
    });
};

function importPlaylistFromFile(pathToFile) {
    try {
        const data = fs.readFileSync(pathToFile, 'utf8');
        playlistTracks = addConsumedFlagToTracks(data.trim().split('\n'));
        numberOfTracks = playlistTracks.length;
        return playlistTracks;
    } catch (err) {
        console.error('Error reading the playlist file:', err);
        return [];
    }
}

// Watch for changes in the playlist file
function watchPlaylistFile(filePath) {
    importPlaylistFromFile(filePath);
    const watcher = chokidar.watch(filePath);
    watcher.on('change', () => {
        console.log('Playlist has been modified.');
        importPlaylistFromFile(filePath);
        console.log('Playlist tracks:');
        console.log(playlistTracks);
        console.log('Number of tracks:');
        console.log(numberOfTracks);
        console.log('Current track:');
        console.log(getTrackPath());
        console.log('Current track index:');
        console.log(getCurrentTrackIndex());
        currentTrack = getTrackPath();
           if (currentTrack.path === currentTrack_saved.path) {
               currentTrack = currentTrack_saved;
               saveJsonToFile(currentTrack_saved, 'db/currentTrack.json');
               trackIndex = getCurrentTrackIndex() % numberOfTracks;
               playlistTracks[trackIndex] = currentTrack_saved;
            } else {
               currentTrack = getTrackPath();
               currentTrack_saved = currentTrack;
               saveJsonToFile(currentTrack_saved, 'db/currentTrack.json');
            }
    });
}

// Path to the playlist file
const playlistUrl = 'playlist/test_playlist.m3u';




// Watch the playlist file for changes
watchPlaylistFile(playlistUrl);


function getCurrentTrackIndex() {
    const startDate = new Date('2024-07-17').setHours(0, 0, 0, 0);
    const currentDate = new Date().setHours(0, 0, 0, 0);
    const elapsedTime = currentDate - startDate;
    const dayInMS = 1000 * 60 * 60 * 24;
    return Math.floor(elapsedTime / dayInMS);
}

function getTrackPath() {
    trackIndex = getCurrentTrackIndex() % numberOfTracks;
    return playlistTracks[trackIndex];
}


let progress_data = {};
// Function to load JSON data from a file
function loadJsonFromFile() {
    try {
        const data = fs.readFileSync('db/progress_data.json', 'utf8');
        progress_data = JSON.parse(data);
        console.log('JSON data loaded successfully:', progress_data);
    } catch (err) {
        console.error('Error loading JSON from file. Resetting progress_data');
        // If the file does not exist, initialize with some default data
        progress_data = {};
    }
}
// Load the JSON data when the application starts
loadJsonFromFile();

// Middleware to check the day
function checkDayChange(req, res, next) {
    const today = new Date().toLocaleString().slice(0, 10); // Current date in YYYY-MM-DD format

    if (lastRequestDate !== today) {
        // It's a new day, so we need to reset the track state
        lastRequestDate = today;
        //currentTrackIndex = (currentTrackIndex + 1) % tracks.length; // Increment current index cyclically
        // Mark all tracks as unconsumed for the new day.
        playlistTracks.forEach(track => track.consumed = false);
        playlistTracks.forEach(track => track.consumed2 = false);
    }
    next();
};

// Function to load JSON data from a file
function loadJsonFromFile2() {
    try {
        const data = fs.readFileSync('db/currentTrack.json', 'utf8');
        currentTrack_saved = JSON.parse(data);
        console.log('JSON data loaded successfully:', currentTrack_saved);
        currentTrack = getTrackPath();
           if (currentTrack.path === currentTrack_saved.path) {
               currentTrack = currentTrack_saved;
               saveJsonToFile(currentTrack_saved, 'db/currentTrack.json');
               trackIndex = getCurrentTrackIndex() % numberOfTracks;
               playlistTracks[trackIndex] = currentTrack_saved;
            } else {
               currentTrack = getTrackPath();
               currentTrack_saved = currentTrack;
               saveJsonToFile(currentTrack_saved, 'db/currentTrack.json');
            }
    } catch (err) {
        console.error('Error loading JSON from file. Resetting');
        currentTrack = getTrackPath();
        currentTrack_saved = currentTrack;
        saveJsonToFile(currentTrack_saved, 'db/currentTrack.json');
    }
}
// Load the JSON data when the application starts
loadJsonFromFile2();

// Function to save JSON CURRENT TRACK data to a file
function saveJsonToFile(data, filename) {
    try {
    fs.writeFile(filename, JSON.stringify(data, null, 2), (err) => {
        if (err) {
            console.error('Error saving JSON to file:', err);
        } else {
            console.log('JSON data saved successfully');
        }
    });
    } catch (err) {
        console.error('Error saving JSON to file.');
    }

}

// Display the imported tracks
//console.log('Playlist tracks:');
//console.log(playlistTracks);
console.log('Tooday track is number ' + getCurrentTrackIndex() + ' of ' + numberOfTracks);
console.log(getTrackPath());
console.log(progress_data);

// // Periodically save JSON data to the file
// setInterval(() => {

//     console.log(currentTrack_saved)
// }, 10000); // Save every 5 seconds

app.get('/next', checkDayChange, (req, res) => {
    //const nextTrackPath = getTrackPath();
    //res.send(nextTrackPath.path);

    currentTrack = getTrackPath();
    
    // Check if the current track has been consumed
    // if (!currentTrack.consumed && (new Date().getHours() >= 8 && new Date().getHours() < 20)) {

    if (!currentTrack.consumed) {
        // Mark the track as consumed
        currentTrack.consumed = true;
    
        // Return the path of the current track
        res.send(currentTrack.path);


        currentTrack_saved = currentTrack;
        saveJsonToFile(currentTrack_saved, 'db/currentTrack.json');

    } else if (!currentTrack.consumed2 && (new Date().getMinutes() >= 5 && new Date().getMinutes() < 59)) {
        
        currentTrack.consumed2 = true;
        res.send(currentTrack.path);

        currentTrack_saved = currentTrack;
        saveJsonToFile(currentTrack_saved, 'db/currentTrack.json');

    } else {

        return res.send();

    };
});

app.put('/progress', (req, res) => {
progress_data = req.body;
console.log(progress_data);
console.log('progress_data is saved to progress_data.json');
saveJsonToFile(progress_data, 'db/progress_data.json');
res.sendStatus(200);
});

app.get('/progress', (req, res) => {
res.send(progress_data);
});

app.get('/array', (req, res) => {
res.json(playlistTracks);
});






// let currentTrackIndex = 0;
// let currentDate = new Date().toDateString();

// function getNextTrackIndex() {
//   const today = new Date().toDateString();
//   if (today !== currentDate) {
//     currentDate = today;
//     currentTrackIndex = (currentTrackIndex + 1) % playlistTracks.length;
//   }
//   return currentTrackIndex;
// }

// app.get('/nextTrack', (req, res) => {
//   const nextTrackIndex = getNextTrackIndex();
//   const nextTrack = playlistTracks[nextTrackIndex];
//   //res.json({ track: nextTrack });
//   res.send(nextTrack);
// });
/////////////////////////////////
/////////////////////////////////
/////////////////////////////////


/////////////////////////////////
////////////CENTRIFUGO///////////
/////////////////////////////////

//const path = require('path');
function authentication(req, res, next) {
    const authheader = req.headers.authorization;
    if (!authheader) {

        res.sendStatus(500);
    }
    try {
    const auth = new Buffer.from(authheader.split(' ')[1],'base64').toString().split(':');
    const user = auth[0];
    const pass = auth[1];
    if (user == 'stepan' && pass == 'hackme') {
        // If Authorized user
        next();
    } else {

        res.sendStatus(500);
    }
   } catch (e) {
    console.error(e.message); 
    console.log("No auth data is supplied"); 
   }
}

// First step is the authentication of  the client
app.use(authentication)
//app.use(express.static(path.join(__dirname, 'public')));
/////////////////////////////////////////////////////////////

app.post('/liq', (req, res) => {

np_data = req.body;

OMFM_send_post_to_centrifugo_on_track_change();
res.sendStatus(200);
});
app.post('/liq', (req, res) => {

np_data = req.body;

OMFM_send_post_to_centrifugo_on_track_change();
res.sendStatus(200);
});
///
async function OMFM_send_post_to_centrifugo_on_track_change() {
  let array = np_data;    
  try {     
      //if (array.now_playing.played_at_timestamp !== null && array.now_playing.played_at_timestamp !== original_timestamp) { 
      if (array.now_playing.song.text !== null && array.now_playing.song.text !== original_timestamp) { 

          // eventEmitter.emit('send_post_to_centrifugo')
          try {
               await centrifugoApiClient.post('', {
               channel: "station:radio",
               data: {
                np: array, 
                spotifyToken: spotifyToken,
                trigger: "track has changed"
                     },
               });
          } catch (e) {
          console.error(e.message);
          }
      original_timestamp = array.now_playing.song.text;
      //original_timestamp = array.now_playing.played_at_timestamp;
      }
  } catch (e) {
      return console.error(e);  
  } 
}

///////////////////////////////
///////////////////////////////
///////////////////////////////
async function OMFM_send_post_to_centrifugo() {
  try {
    await centrifugoApiClient.post('', {
        channel: "station:radio",
        data: {np: np_data, spotifyToken: spotifyToken},
      });
  } catch (e) {
    console.error(e.message);
  }
}

eventEmitter.on('OMFM_send_post_to_centrifugo', OMFM_send_post_to_centrifugo);

const np_interval_CF = setInterval(() => {
eventEmitter.emit('OMFM_send_post_to_centrifugo')
}, 15000);
/////////////////////////////////
/////////////////////////////////
/////////////////////////////////






const port = process.env.PORT || 9999
server.listen(port, () => console.log(`Listening on ${port}`))
//////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////
