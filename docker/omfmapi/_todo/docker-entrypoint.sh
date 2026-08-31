#!/bin/sh
# Start the Node.js API
npm start & #using & it's in the back

# Start the Python script
python3 hls_listeners_api.py &

# Keep the container running indefinitely (optional, if the python script exits on its own)
wait