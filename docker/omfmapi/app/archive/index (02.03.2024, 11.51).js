const express = require('express');

const app = express();

var original_timestamp = 0;

// const { readFileSync } = require('fs');
const fs = require('fs');

  let np;
  let array;
  fs.readFile('/var/www/html/omfm/nowplaying.json', (err,data) => {
             if(err) { 
             return console.log(err);
             }
             np = data; 
    });

    const interval = setInterval(() => {
    fs.readFile('/var/www/html/omfm/nowplaying.json', (err,data) => {
             if(err) { 
             return console.log(err);
             }
             np = data;
             try {
             array = JSON.parse(np);
             } catch (e) {
             return console.error(e); // error in the above string
             }
             
    });
    }, 1000);

app.get('/', (req, res) => {
  res.send(`<!DOCTYPE html><html><body><h1>omFM Radio SSE updates! add "subscribe" to get new updates!</h1></body></html>`);
});
app.get('/subscribe', (req, res) => {
    // TODO: Add subscription code here
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.flushHeaders();

    res.write('event: message\n');
    res.write(`data: ${np}\n\n`); 
 
    //Send a subsequent message every n seconds
    const np_interval = setInterval(() => {
             res.write('event: message\n');
             res.write(`data: ${np}\n\n`); 
    }, 30000);

    const newTrack_interval = setInterval(() => {
        if (array.nowplaying.played_at_timestamp !== original_timestamp) {
             res.write('event: message\n');
             res.write(`data: ${np}\n\n`); 
            original_timestamp = array.nowplaying.played_at_timestamp;
            };
    }, 1000);
   
    // 
    req.on('close', () => {
    clearInterval(np_interval);
    clearInterval(newTrack_interval);
  });
});

app.listen(9999, () => console.log('App listening: http://localhost:9999'));

