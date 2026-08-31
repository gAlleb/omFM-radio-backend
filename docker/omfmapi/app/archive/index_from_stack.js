const amqp = require('amqplib');

const rabbitmqServerUrl = 'amqp://localhost';
const queueName = 'best_queue';

let connection = null;
let channel = null;

async function setupConnection() {
  try {
    connection = await amqp.connect(rabbitmqServerUrl);
    connection.on('error', (err) => {
      if (err.message.includes('Connection closed')) {
        console.error('Connection closed, reconnecting...');
        setTimeout(setupConnection, 5000); // Retry connection after a delay
      } else {
        console.error('Connection error:', err.message);
      }
    });

    channel = await connection.createChannel();

    // Create a durable queue
    await channel.assertQueue(queueName, { durable: true });

    console.log('Connected to RabbitMQ');

    // Start the consumer
    startConsumer();
  } catch (error) {
    console.error('Error connecting to RabbitMQ:', error.message);

    // Retry connection after a delay
    setTimeout(setupConnection, 5000);
  }
}

function startConsumer() {
  if (!channel) {
    console.error('Channel is not available, skipping consumer start.');
    return;
  }

  channel.consume(queueName, async (msg) => {
    if (msg !== null) {
      try {
        // Process the message
        console.log('Received message:', msg.content.toString());

        // Simulate a processing delay (replace this with your actual processing logic)
        await new Promise((resolve) => setTimeout(resolve, 1000));

        // Acknowledge the message
        channel.ack(msg);
      } catch (err) {
        console.error('Error processing message:', err.message);
        // Handle message processing errors as needed
      }
    }
  });

  channel.on('close', () => {
    console.error('Channel closed, reconnecting...');
    setTimeout(setupConnection, 5000); // Restart the consumer after a delay
  });

  channel.on('error', (error) => {
    console.error('Channel error:', error.message);
    // Handle channel errors as needed
  });

  console.log('Consumer started');
}

setupConnection();