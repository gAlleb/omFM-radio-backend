const express = require('express');

const app = express();

var original_timestamp = 0;

app.get('/', (req, res) => {
  res.send(`<!DOCTYPE html><html><body><h1>omFM Radio SSE updates! add "subscribe" to get new updates!</h1></body></html>`);
});
// const { readFileSync } = require('fs');
const fs = require('fs');
app.get('/subscribe', (req, res) => {
    // TODO: Add subscription code here
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.flushHeaders();

    // Sync Version
    //
    // var np = fs.readFileSync('/var/www/html/omfm/nowplaying_sse.json')
    // res.write('event: message\n');
    // res.write(`data: ${np}\n\n`);
    // const newTrack_interval = setInterval(() => {
    // var np = fs.readFileSync('/var/www/html/omfm/nowplaying_sse.json')
    // var array = JSON.parse(np);
    //    if (array.nowplaying.played_at_timestamp !== original_timestamp) {
    //    res.write('event: message\n');
    //    res.write(`data: ${np}\n\n`);
    //    original_timestamp = array.nowplaying.played_at_timestamp;
    //    };
    // }, 1000);
    // // Send a subsequent message every n seconds
    // const np_interval = setInterval(() => {
    //     np = fs.readFileSync('/var/www/html/omfm/nowplaying_sse.json')
    //     res.write('event: message\n');
    //     res.write(`data: ${np}\n\n`);
    // }, 20000);

    // Async Version
    fs.readFile('/var/www/html/omfm/nowplaying_sse.json', (err,np) => {
             if(err) { 
             return console.log(err);
             }
             res.write('event: message\n');
             res.write(`data: ${np}\n\n`); 
    });

    const newTrack_interval = setInterval(() => {
        fs.readFile('/var/www/html/omfm/nowplaying_sse.json', (err,np) => { 
             if(err) { 
             return console.log(err);
             }
             let array;
             try {
             array = JSON.parse(np);
             } catch (e) {
             return console.error(e); // error in the above string
             }
             if (array.nowplaying.played_at_timestamp !== original_timestamp) {
             res.write('event: message\n');
             res.write(`data: ${np}\n\n`);
             original_timestamp = array.nowplaying.played_at_timestamp;
             };
         });
    }, 1000);

    //Send a subsequent message every n seconds
    const np_interval = setInterval(() => {
         fs.readFile('/var/www/html/omfm/nowplaying_sse.json', (err,np) => {
             if(err) { 
             return console.log(err);
             }
             res.write('event: message\n');
             res.write(`data: ${np}\n\n`); 
         });
    }, 15000);
    
    // 
    req.on('close', () => {
    clearInterval(np_interval);
    clearInterval(newTrack_interval);
  });
});

app.listen(9999, () => console.log('App listening: http://localhost:9999'));

