const express = require('express');
const app = express();
const PORT = 9999;
const EventEmitter = require('events');
const eventEmitter = new EventEmitter();
eventEmitter.setMaxListeners(500);
// const { readFileSync } = require('fs');
const fs = require('fs');
const redis = require('redis');

const amqp = require("amqplib");

let np; 
let original_timestamp = 0;


var channel, connection;connectQueue()  
 
async function connectQueue() {
        try {        connection = await amqp.connect("amqp://stepan:hackme@localhost:5672/liq");
        
    connection.on('error', (err) => {
      if (err.message.includes('Connection closed')) {
        console.error('Connection closed, reconnecting...');
        setTimeout(connectQueue, 5000); // Retry connection after a delay
      } else {
        console.error('Connection error:', err.message);
      }
    });

        channel    = await connection.createChannel()
        await channel.assertQueue("liquidsoap")
        console.log('Connected to RabbitMQ');
        channel.consume("liquidsoap", data => { 
     
            //console.log(`${Buffer.from(data.content)}`);
            //np = Buffer.from(data.content.toString('utf-8'), 'base64');
            np = data.content;
            //eventEmitter.emit('send_np'); 
                 let array;
                 try { 
                 array = JSON.parse(np);
                  } catch (e) {
                 return console.error(e);  
                 }     
                 try {     
                 if (array.nowplaying.played_at_timestamp !== null && array.nowplaying.played_at_timestamp !== original_timestamp) {
                 eventEmitter.emit('send_np');
                 original_timestamp = array.nowplaying.played_at_timestamp;
                 }
                 } catch (e) {
                 return console.error(e);  
                 } 
            //channel.ack(data); 
                 },{
                 noAck: false
                 });

        channel.on('close', () => {
        console.error('Channel closed, reconnecting...');
        setTimeout(connectQueue, 5000); // Restart the consumer after a delay
        });
          } catch (error) {
        console.error('Error connecting to RabbitMQ:', error.message);
        setTimeout(connectQueue, 5000)
        }
}


const np_interval = setInterval(() => {
     eventEmitter.emit('send_np');
     eventEmitter.emit('send_np');
}, 20000);

app.get('/subscribe', (req, res) => {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    //res.setHeader('Access-Control-Allow-Origin', '*');
    res.flushHeaders();
   
    function  send_np() {
    res.write('event: message\n');
    res.write(`data: ${np}\n\n`); 
    }
    eventEmitter.on('send_np', send_np);
    eventEmitter.emit('send_np');

    req.on('close', () => {
    //clearInterval(np_interval);
  });
});

app.listen(PORT, () => console.log(':9999'));

///////////////////////////////////
    // function  send_np() {
    // res.write('event: message\n');
    // res.write(`data: ${np}\n\n`); 
    // }
    // eventEmitter.on('send_np', send_np);
    // eventEmitter.emit('send_np');
    // const np_interval = setInterval(() => {
    // send_np();
    // }, 20000);
// app.get('/', (req, res) => {
//   res.send(`<!DOCTYPE html><html><body><h1>omFM Radio SSE updates! add <a href="https://omfm.ru/sse/subscribe">"subscribe"</a> to get new updates!</h1></body></html>`);
// });