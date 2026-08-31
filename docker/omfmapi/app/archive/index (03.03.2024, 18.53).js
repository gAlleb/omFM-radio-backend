const express = require('express');
const app = express();
const PORT = 9999;
const EventEmitter = require('events');
const eventEmitter = new EventEmitter();
eventEmitter.setMaxListeners(500);
// const { readFileSync } = require('fs');
const fs = require('fs');

let np; 
let original_timestamp = 0;

const interval = setInterval(() => {
    fs.readFile('/var/www/html/omfm/nowplaying.json', (err,data) => {
             if(err) { 
             return console.log(err);
             }
             np = data;
             let array;
             try {
             array = JSON.parse(np);
             } catch (e) {
             return console.error(e); // error in the above string
             }     
             if (array.nowplaying.played_at_timestamp !== null && array.nowplaying.played_at_timestamp !== original_timestamp) {
             eventEmitter.emit('send_np');
             original_timestamp = array.nowplaying.played_at_timestamp;
             }; 
    });
}, 1000);

const np_interval = setInterval(() => {
    eventEmitter.emit('send_np');
}, 20000);

app.get('/subscribe', (req, res) => {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.flushHeaders();

    function  send_np() {
    res.write('event: message\n');
    res.write(`data: ${np}\n\n`); 
    }
     
    eventEmitter.on('send_np', send_np);
    eventEmitter.emit('send_np');

    // const np_interval = setInterval(() => {
    // send_np();
    // }, 20000);

    req.on('close', () => {
    //clearInterval(np_interval);
  });
});

app.listen(PORT, () => console.log(':9999'));

///////////////////////////////////
// app.get('/', (req, res) => {
//   res.send(`<!DOCTYPE html><html><body><h1>omFM Radio SSE updates! add <a href="https://omfm.ru/sse/subscribe">"subscribe"</a> to get new updates!</h1></body></html>`);
// });