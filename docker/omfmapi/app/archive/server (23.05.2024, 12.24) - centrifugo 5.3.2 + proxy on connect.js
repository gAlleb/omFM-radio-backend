const express = require('express');
const app = express();
app.use(express.json());
const server = require('http').createServer(app);
const EventEmitter = require('events');
const eventEmitter = new EventEmitter();
eventEmitter.setMaxListeners(500);
let np, np_data, np_data_coma; 
let original_timestamp = 0;
const axios = require('axios');
const centrifugoApiClient = axios.create({
  baseURL: `http://127.0.0.1:9998/api/publish`,
  headers: {
    'X-API-key': 'hackme',
    'Content-Type': 'application/json',
  },
});
/////////////////////////////////
////////////CENTRIFUGO///////////
/////////////////////////////////

//const path = require('path');
function authentication(req, res, next) {
    const authheader = req.headers.authorization;
    if (!authheader) {
        // let err = new Error('You are not authenticated!');
        // res.setHeader('Authorization', 'Basic');
        // err.status = 401;
        // return next(err)
        res.sendStatus(500);
    }
    const auth = new Buffer.from(authheader.split(' ')[1],'base64').toString().split(':');
    const user = auth[0];
    const pass = auth[1];
    if (user == 'stepan' && pass == 'hackme') {
        // If Authorized user
        next();
    } else {
        // let err = new Error('You are not authenticated!');
        // res.setHeader('Authorization', 'Basic');
        // err.status = 401;
        // return next(err);
        res.sendStatus(500);
    }
}


app.post('/centrifugo/connect', (req, res) => {
console.log(req.body.channels)

if (req.body.channels !== null && req.body.channels == 'station:radio') {

res.json({
      result: {
        user: '',
        channels: req.body.channels,
        data: [

          { 
            channel: 'station:radio',
                pub: { data: {
                              np: np_data, 
                              current_time: Date.now()
                             }
                     }
              },
        ]
      }
    });

} else if (req.body.channels !== null && req.body.channels == 'station:coma') {
  res.json({
      result: {
        user: '',
        channels: req.body.channels,
        data: [

          { 
            channel: 'station:coma',
                pub: { data: {
                              np: np_data_coma, 
                              current_time: Date.now()
                             }
                     }
              }  
        ]
      }
    });
}
});

// First step is the authentication of  the client
app.use(authentication)
//app.use(express.static(path.join(__dirname, 'public')));
//////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////

app.post('/liq', (req, res) => {
// if (!channel2) {
//   console.error('Channel2 is not available');
//   return;
// } 
np_data = req.body;
// Just change to channel and remove all that provider shit!!!!!!!!!!!!!!!!!!!!!!!!!!
//sendData(np_data);  // console.log("A message is sent to queue")
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
                current_time: Date.now(), 
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
///
app.post('/liq2', (req, res) => {
// if (!channel2) {
//   console.error('Channel2 is not available');
//   return;
// } 
np_data_coma = req.body;
// Just change to channel and remove all that provider shit!!!!!!!!!!!!!!!!!!!!!!!!!!
//sendData(np_data);  // console.log("A message is sent to queue")
COMAOMFM_send_post_to_centrifugo_on_track_change();
res.sendStatus(200);
});
///
async function COMAOMFM_send_post_to_centrifugo_on_track_change() {
  let array = np_data_coma;    
  try {     
      //if (array.now_playing.played_at_timestamp !== null && array.now_playing.played_at_timestamp !== original_timestamp) { 
      if (array.now_playing.song.text !== null && array.now_playing.song.text !== original_timestamp) { 

          // eventEmitter.emit('send_post_to_centrifugo')
          try {
               await centrifugoApiClient.post('', {
               channel: "station:coma",
               data: {
                np: array, 
                current_time: Date.now(), 
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
        data: {np: np_data, current_time: Date.now()},
      });
  } catch (e) {
    console.error(e.message);
  }
}
async function COMAOMFM_send_post_to_centrifugo() {
  try {
    await centrifugoApiClient.post('', {
        channel: "station:coma",
        data: {np: np_data_coma, current_time: Date.now()},
      });
  } catch (e) {
    console.error(e.message);
  }
}
eventEmitter.on('OMFM_send_post_to_centrifugo', OMFM_send_post_to_centrifugo);
eventEmitter.on('COMAOMFM_send_post_to_centrifugo', COMAOMFM_send_post_to_centrifugo);

const np_interval_CF = setInterval(() => {
eventEmitter.emit('OMFM_send_post_to_centrifugo')
eventEmitter.emit('COMAOMFM_send_post_to_centrifugo')

}, 15000);
/////////////////////////////////
/////////////////////////////////
/////////////////////////////////
const port = process.env.PORT || 9999
server.listen(port, () => console.log(`Listening on ${port}`))
//////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////
