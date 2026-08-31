const express = require('express');
const app = express();
app.use(express.json({limit : 52428800}));
const server = require('http').createServer(app);
const WebSocket = require('ws');
const wss = new WebSocket.Server({ server: server });

//const io = require('socket.io')(server);


app.use(express.json())
const EventEmitter = require('events');
const eventEmitter = new EventEmitter();
eventEmitter.setMaxListeners(500);
const amqp = require("amqplib");
const amqp2 = require("amqplib");
let np; 
let original_timestamp = 0;
var channel, channel2, connection, connection2;



// socket.io

// io.on('connection', (socket) => {


//     socket.emit('message', (np));

//     socket.on('message', (message) =>
//         console.log('Message: ', message)
//     );

//     socket.on('disconnect', () => {
        
      
//     });
// });

// WebSocket
wss.on('connection', function (ws) {
    console.log('New connection')

    ws.on('message', function (data) {
        console.log('New message: ' + data);
    });

    // Broadcast a message to all connected clients
    eventEmitter.emit('send_np_WS');


    ws.on('close', () => {
    console.log('client diconnected')
    });
})

function  send_np_WS() {
    wss.clients.forEach((client) => {
       client.send(`${np}`);
    });
};
eventEmitter.on('send_np_WS', send_np_WS);

const np_interval_WS = setInterval(() => {
     eventEmitter.emit('send_np_WS');
}, 20000);
//


connectConsumer(); 

async function connectConsumer() {
    try { 

      connection = await amqp.connect("amqp://stepan:hackme@localhost:5672/");
        
      connection.on('error', (err) => {
      if (err.message.includes('Connection closed')) {
        console.error('Connection closed, reconnecting...');
        setTimeout(connectConsumer, 5000); // Retry connection after a delay
      } else {
        console.error('Connection error:', err.message);
      }
      });

      channel = await connection.createChannel()

      connectConsumerQueue()
      
    } catch (error) {
      console.error('Error connecting to RabbitMQ:', error.message);
      setTimeout(connectConsumer, 5000)
    }
}

async function connectConsumerQueue() {
    try { 

      await channel.assertQueue("liquidsoapQueue", { durable: false } )
      console.log('Consumer - Connected to RabbitMQ');
        
      startConsumer();

    } catch (error) {
      console.error('Error creating ConsumerQueue:', error.message);
      setTimeout(connectConsumer, 5000)
    }

  }

async function startConsumer() {
  if (!channel) {
    console.error('Channel is not available, skipping consumer start.');
    return;
  }

  await channel.consume("liquidsoapQueue", async (data) => {
    if (data !== null) {
       
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
                 if (array.pub.data.np.now_playing.played_at_timestamp !== null && array.pub.data.np.now_playing.played_at_timestamp !== original_timestamp) {
                
                 eventEmitter.emit('send_np');
                 eventEmitter.emit('send_np_WS');

                 original_timestamp = array.pub.data.np.now_playing.played_at_timestamp;
                 }
                 } catch (e) {
                 return console.error(e);  
                 } 
            channel.ack(data);             
    }
  } // ,{noAck: false} Socket closed abruptly during opening handshake
  );

  channel.on('close', () => {
    console.error('Channel closed, reconnecting...');
    setTimeout(connectConsumer, 5000); // Restart the consumer after a delay
  });
  channel.on('error', (error) => {
    console.error('Channel error:', error.message);
  });

  console.log('Consumer started');
}
     
const np_interval = setInterval(() => {
     eventEmitter.emit('send_np');
}, 20000);

app.get('/sse', (req, res) => {
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
/////////////////////////////////
/////////////////////////////////
/////////////////////////////////
connectProvider()

async function connectProvider() {
    try {

      connection2 = await amqp2.connect("amqp://stepan:hackme@localhost:5672/");
        
      connection2.on('error', (err) => {
      if (err.message.includes('Connection closed')) {
        console.error('Connection closed, reconnecting...');
        setTimeout(connectProvider, 5000); // Retry connection after a delay
      } else {
        console.error('Connection error:', err.message);
      }
      });
      
      channel2    = await connection2.createChannel()
 
      connectProviderExchange()

    } catch (error) {
      console.error('Error connecting to RabbitMQ:', error.message);
      setTimeout(connectProvider, 5000)
    }
}
async function connectProviderExchange() {
      await channel2.assertExchange('liquidsoap', 'direct', { durable: false });
      await channel2.assertQueue('liquidsoapQueue', { durable: false });
      await channel2.bindQueue('liquidsoapQueue', 'liquidsoap', 'dsfdsf3r325gf');
      console.log('Provider - Connected to RabbitMQ');

      channel2.on('close', () => {
      console.error('Channel2 closed, reconnecting...');
      setTimeout(connectProvider, 5000); // Restart the consumer after a delay
      });

      channel2.on('error', (error) => {
      console.error('Channel2 error:', error.message);
      });

      console.log('Provider started');
}
async function sendData (data) {
    try {
          //await channel2.sendToQueue('liquidsoapQueue', Buffer.from(JSON.stringify(data)));
          await channel2.publish('liquidsoap', 'dsfdsf3r325gf', Buffer.from(JSON.stringify(data)));
        } catch (error) {
          console.error('Error connecting to RabbitMQ:', error.message);
    }
}

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
// First step is the authentication of  the client
app.use(authentication)
//app.use(express.static(path.join(__dirname, 'public')));
app.post('/liq', (req, res) => {
  if (!channel2) {
    console.error('Channel2 is not available');
    return;
  } 
  const data = req.body;
  //res.send(data);    // echo the result back 
  // Just change to channel and remove all that provider shit!!!!!!!!!!!!!!!!!!!!!!!!!!
  sendData(data);  // pass the data to the function we defined    console.log("A message is sent to queue")
  
  res.sendStatus(200);
});
/////////////////////////////////
/////////////////////////////////
/////////////////////////////////
const port = 9999
server.listen(port, () => console.log('Listening on', port))
///////////////////////////////////
//
// app.get('/', (req, res) => {
//   res.send(`<!DOCTYPE html><html><body><h1>omFM Radio SSE updates! add <a href="https://omfm.ru/sse/subscribe">"subscribe"</a> to get new updates!</h1></body></html>`);
// });