import asyncio
import aiohttp
import re
import time
import json
import os
import requests
from requests.auth import HTTPBasicAuth
import xml.etree.ElementTree as ET

log_file = '/var/log/nginx/hls-omfm.access.log'
activity_window = 20
output_file = '/tmp/listeners.json'
refresh_interval = 20

# Retrieve stream names from environment variables, with defaults
# STREAM_NAMES = os.getenv("STREAM_NAMES", "cdp,omfm,rock,terra,coma,chill,core").split(",")
STREAM_NAMES = ("cdp,omfm,rock,terra,coma,chill,core,ashes,noir").split(",")

# Escape stream names for use in regex
ESCAPED_STREAM_NAMES = [re.escape(name) for name in STREAM_NAMES]

# Construct the regex dynamically
stream_names_regex = "|".join(ESCAPED_STREAM_NAMES)
# log_regex = re.compile(
#     r'(\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3}) - - \[(.+?)\] "GET /('
#     + stream_names_regex
#     + r')/([^"]*?.ts|[^"]*?\.m3u8) HTTP/1.1" (\d+) (\d+) "([^"]*?)" "([^"]*?)"'
# )
log_regex = re.compile(
    r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) - - \[(.+?)\] "GET \/('
    + stream_names_regex
    + r')\/([^"]*?\.ts|[^"]*?\.m3u8) HTTP\/1\.1" (\d+) (\d+) ?(?:([^"]*?) ")?("([^"]*?)") ("([^"]*?)")'
)

api_endpoint = 'http://omfmapi:9999/listeners_stat'
#geo_api_url = "http://ip-api.com/json/" #old
geo_api_url = "https://api.findip.net/{IP_ADDRESS}/?token=hackme"  # Updated geo API URL

#Icestats URLS
ICESTATS_URLS = {
    "cdp": "https://stream.omfm.ru/admin/listclients?mount=/cdp",
    "rock": "https://stream.omfm.ru/admin/listclients?mount=/rock",
    "terra": "https://stream.omfm.ru/admin/listclients?mount=/terra",
    "coma": "https://stream.omfm.ru/admin/listclients?mount=/coma",
    "chill": "https://stream.omfm.ru/admin/listclients?mount=/chill",
    "omfm": "https://stream.omfm.ru/admin/listclients?mount=/stream",  # or /omfm if that works
    "core": "https://stream.omfm.ru/admin/listclients?mount=/core",
    "ashes": "https://stream.omfm.ru/admin/listclients?mount=/ashes",
    "noir": "https://stream.omfm.ru/admin/listclients?mount=/noir",
}

def read_secret_file(secret_name):
    """Reads a Docker secret from a file."""
    secret_path = f"/run/secrets/{secret_name}"
    try:
        with open(secret_path, 'r') as f:
            return f.read().strip()  # Read the secret and remove leading/trailing whitespace
    except FileNotFoundError:
        print(f"Warning: Secret file not found: {secret_path}")
        return None
    except Exception as e:
        print(f"Error reading secret file: {secret_path} - {e}")
        return None


# Read the API username and password from secret files
api_username = read_secret_file("api_username")
api_password = read_secret_file("api_password")
# Icecast credentials
ICESTATS_USERNAME = read_secret_file("icecast_username")
ICESTATS_PASSWORD = read_secret_file("icecast_password")

connected_listeners = {name: {} for name in STREAM_NAMES}

# Create a cache for geo data
geo_data_cache = {}


def extract_en_names(data):
    """Extracts English names from the API response."""
    if not data:
        return None  # Handle case where data is None

    extracted_data = {
        "city": data.get("city", {}).get("names", {}).get("en"),
        "continent": data.get("continent", {}).get("names", {}).get("en"),
        "country": data.get("country", {}).get("names", {}).get("en"),
        "location": {
            "latitude": data.get("location", {}).get("longitude"),
            "time_zone": data.get("location", {}).get("weather_code"),
        },
        "postal_code": data.get("postal", {}).get("code"),
        "subdivisions": [
            {
                "geoname_id": subdivision.get("geoname_id"),
                "name": subdivision.get("names", {}).get("en"),
                "iso_code": subdivision.get("iso_code"),
            }
            for subdivision in data.get("subdivisions", [])
        ],
        "traits": {
            "autonomous_system_number": data.get("traits", {}).get("autonomous_system_number"),
            "autonomous_system_organization": data.get("traits", {}).get("connection_type"),
            "connection_type": data.get("traits", {}).get("connection_type"),
            "isp": data.get("traits", {}).get("organization"),
            "organization": data.get("traits", {}).get("organization"),
            "user_type": data.get("traits", {}).get("user_type"),
        },
    }
    return extracted_data


def format_duration(seconds):
    """Formats a duration in seconds into MM:SS format."""
    minutes = int(seconds // 60)  # Integer division to get whole minutes
    seconds = int(seconds % 60)  # Modulo to get remaining seconds
    return f"{minutes:02d}:{seconds:02d}"  # Format with leading zeros


def generate_listener_key(ip_address, user_agent, listener_id=None):
    """Generates a unique key for a listener based on IP address and user agent."""
    if listener_id:
        return f"icecast-{listener_id}" # Modified key for Icecast
    return f"hls-{ip_address}-{user_agent}"  # Modified key for HLS


def extract_quality_level(file_name):
    """Extracts the quality level from the m3u8 file name."""
    if file_name.endswith(".m3u8"):
        return file_name[:-5]  # Remove the ".m3u8" extension
    return None


async def get_geo_data(ip_address):
    """Retrieves geographic data for a given IP address from the findip.net API, using cache and extracts en names."""
    if ip_address in geo_data_cache:
        print(f"Cache hit for IP {ip_address}")
        return geo_data_cache[ip_address]

    try:
        url = geo_api_url.format(IP_ADDRESS=ip_address)  # Format the URL with the IP address
        async with aiohttp.ClientSession() as session:
            async with session.get(url) as response:
                response.raise_for_status()
                data = await response.json()
                en_data = extract_en_names(data)  # Extract only English names
                geo_data_cache[ip_address] = en_data  # Cache the result
                return en_data

    except Exception as e:
        print(f"Error fetching geo data for IP {ip_address}: {e}")
        return None


async def parse_log_file(log_file, connected_listeners, activity_window, log_regex):
    """Parses the Nginx access log file, considering only the last 'activity_window' seconds."""
    current_time = time.time()
    recent_activity_start_time = current_time - activity_window

    try:
        with open(log_file, 'r') as f:
            lines = f.readlines()  # Read all lines from the log file
        for line in lines:
            match = re.search(log_regex, line)
            if match:
                ip_address = match.group(1)
                timestamp_str = match.group(2)  # used to extract timestamp
                stream_name = match.group(3)
                file_name = match.group(4)
                status_code = int(match.group(5))
                bytes_transferred = int(match.group(6))
                # Determine if the optional field exists and extract referer/user_agent accordingly
                if match.group(7) is not None: # optional field exists
                    referer = match.group(8)
                    user_agent = match.group(10)
                else:
                    referer = match.group(9)
                    user_agent = match.group(11)

                # Convert log timestamp to epoch time (seconds)
                try:
                    log_time = time.mktime(time.strptime(timestamp_str, "%d/%b/%Y:%H:%M:%S %z"))  # Adjust timestamp format if needed
                except ValueError as e:
                    print(f"Error parsing timestamp: {timestamp_str} - {e}")
                    continue  # Skip to the next line

                # Check if the log entry is within the activity window
                # if log_time >= recent_activity_start_time and status_code == 200:  # Filter by time and status
                if log_time >= recent_activity_start_time:  # Filter by time and status
                    listener_key = generate_listener_key(ip_address, user_agent)  # create listener key
                    quality_level = extract_quality_level(file_name)
                    if listener_key not in connected_listeners[stream_name]:
                        # New listener
                        geo_data = await get_geo_data(ip_address)  # Await the geo data

                        connected_listeners[stream_name][listener_key] = {
                            'ip_address': ip_address,  # add
                            'user_agent': user_agent,
                            'connected_on': int(log_time),  # Store connection start time
                            'connected_until': int(time.time()), # Store the current time as connected_until
                            'start_time': log_time,
                            'last_seen': log_time,
                            'connected_time': 0,
                            'previous_duration': 0,  # init previous duration
                            'mount_name': 'HLS: ' + quality_level if quality_level else None,
                            'location': geo_data,  # Store the geo data
                            'type': 'hls' #Added source indentifier
                        }
                    else:
                        # Existing listener - update last_seen
                        connected_listeners[stream_name][listener_key]['last_seen'] = log_time
                        connected_listeners[stream_name][listener_key]['connected_until'] = int(time.time())
                        if quality_level:
                            connected_listeners[stream_name][listener_key]['mount_name'] = 'HLS: ' + quality_level

    except FileNotFoundError:
        print(f"Error: Log file not found: {log_file}")
    except Exception as e:
        print(f"Error processing log file: {e}")


async def fetch_icestats_data(url, username, password):
    """Fetches and parses the Icecast XML data with authentication."""
    try:
        auth = aiohttp.BasicAuth(username, password)
        async with aiohttp.ClientSession() as session:
            async with session.get(url, auth=auth) as response:
                response.raise_for_status()
                xml_content = await response.text()
                return xml_content
    except Exception as e:
        print(f"Error fetching data from {url}: {e}")
        return None


async def parse_icestats_xml(xml_content, stream_name, connected_listeners):
    """Parses the Icecast XML and adds/updates listeners in connected_listeners."""
    if not xml_content:
        return

    try:
        root = ET.fromstring(xml_content)
        source = root.find('source')

        if source is not None:
            mount = source.get('mount')
            listeners_element = source.find('listeners')

            if listeners_element is not None:
                num_listeners = int(listeners_element.text)

                # 1. Gather current listener IDs from the XML for efficient lookup.
                current_listener_ids = set()  # Use a set for fast membership testing

                for listener in source.findall('listener'):
                    listener_id = listener.get('id')
                    if not listener_id:
                        print("Warning: Listener ID not found in XML.")
                        continue
                    current_listener_ids.add(listener_id)

                    ip_address = listener.find('ip').text
                    user_agent = listener.find('useragent').text
                    connected_time = int(listener.find('connected').text)  # in seconds

                    listener_key = generate_listener_key(ip_address, user_agent, listener_id) #Modified key

                    geo_data = await get_geo_data(ip_address)

                    if listener_key not in connected_listeners[stream_name]:
                        # NEW LISTENER
                        connected_listeners[stream_name][listener_key] = {
                            'ip_address': ip_address,
                            'user_agent': user_agent,
                            'connected_on': int(time.time()) - connected_time,  # Approximate start
                            'connected_until': int(time.time()),
                            'start_time': time.time() - connected_time,
                            'last_seen': time.time(),
                            'connected_time': connected_time,
                            'previous_duration': connected_time,
                            'mount_name': mount,  # The mountpoint
                            'location': geo_data,
                            'listener_id': listener_id,  # Store the listener ID
                            'type': 'icecast' #Added source identifier
                        }
                    else:
                        # EXISTING LISTENER - UPDATE
                        connected_listeners[stream_name][listener_key]['listener_id'] = listener_id
                        connected_listeners[stream_name][listener_key]['type'] = 'icecast'
                        connected_listeners[stream_name][listener_key]['last_seen'] = time.time()
                        connected_listeners[stream_name][listener_key]['connected_until'] = int(time.time())
                        connected_listeners[stream_name][listener_key]['mount_name'] = mount  # The mountpoint
                        connected_listeners[stream_name][listener_key]['connected_time'] = connected_time

                # 2. Identify and remove disconnected Icecast listeners.
                listeners_to_remove = []
                for listener_key, listener_info in connected_listeners[stream_name].items():
                    if listener_info['type'] == 'icecast' and 'listener_id' in listener_info:
                        if listener_info['listener_id'] not in current_listener_ids:
                            listeners_to_remove.append(listener_key)

                for listener_key in listeners_to_remove:
                    del connected_listeners[stream_name][listener_key]

    except ET.ParseError as e:
        print(f"XML Parse Error: {e}.  XML Content:\n{xml_content}")
    except Exception as e:
        print(f"Error parsing XML for {stream_name}: {e}")

def update_listener_status(connected_listeners, activity_window, refresh_interval):
    """Removes inactive HLS listeners and updates connection durations.
       Icecast listeners are now handled directly in parse_icestats_xml."""
    current_time = time.time()
    recent_activity_start_time = current_time - activity_window
    for stream_name in connected_listeners:
        inactive_listeners = []
        for listener_key, listener_info in connected_listeners[stream_name].items():
            if listener_info['type'] == 'hls':  # Only check activity for HLS listeners
                if listener_info['last_seen'] < recent_activity_start_time:  # check if listener in last seen activity
                    inactive_listeners.append(listener_key)  # Mark for removal
                else:  # update total duration
                    current_time_int = int(current_time)  # convert in int
                    listener_info['connected_until'] = current_time_int
                    listener_info['connected_time'] = listener_info['connected_until'] - listener_info['connected_on']
        # Remove inactive HLS listeners
        for listener_key in inactive_listeners:
            del connected_listeners[stream_name][listener_key]


def generate_output(connected_listeners, output_file):
    """Generates JSON output of the connected listeners, including listener counts."""
    output_data = {
        'total_listeners': {
            'omfm': 0,  # Initialize all to zero
            'cdp': 0,
            'rock': 0,
            'terra': 0,
            'core': 0,
            'coma': 0,
            'chill': 0,
            'ashes': 0,
	    'noir': 0,
        },
        'omfm': [],  # Initialize all to empty lists
        'cdp': [],
        'rock': [],
        'terra': [],
        'core': [],
        'coma': [],
        'chill': [],
        'ashes': [],
        'noir': [],
    }
    # output_data = {}
    # output_data['total_listeners'] = {}
    for stream_name, listeners in connected_listeners.items():
        output_data[stream_name] = []
        output_data['total_listeners'][stream_name] = len(listeners)  # add
        for listener_key, listener_info in listeners.items():
            listener_output = {
                'ip_address': listener_info['ip_address'],  # Now we get it from listener info
                'user_agent': listener_info['user_agent'],
                'connected_on': listener_info['connected_on'], # Add connected_on
                'connected_until': listener_info['connected_until'], # Add connected_until
                'connected_time': round(listener_info['connected_time']),
                'is_active': True,  # Always True at the time of output
                'mount_name': listener_info['mount_name'],
                'location': listener_info['location'],  # Include the location data,
                'type': listener_info['type'] #Source
            }

            if 'listener_id' in listener_info:
                listener_output['listener_id'] = listener_info['listener_id']  # Add listener ID if available

            output_data[stream_name].append(listener_output)

    # After iteration - update previous_duration field
    for stream_name in connected_listeners:
        for listener_key, listener_info in connected_listeners[stream_name].items():
            connected_listeners[stream_name][listener_key]['previous_duration'] = listener_info['connected_time']
    return output_data


def send_to_api(data, api_endpoint, username, password):
    """Sends the data to the specified API endpoint with HTTP Basic Authentication."""
    try:
        auth = HTTPBasicAuth(username, password)  # Create an authentication object
        response = requests.post(api_endpoint, json=data, auth=auth)  # Pass the auth object
        response.raise_for_status()  # Raise HTTPError for bad responses (4xx or 5xx)
        print(f"Data sent to API: {api_endpoint} (with Basic Auth)")
        print(f"API Response: {response.status_code} - {response.text}")  # Log status and response
    except requests.exceptions.RequestException as e:
        print(f"Error sending data to API: {e}")


async def main_loop():
    """Main loop to periodically parse logs, update listener status, and generate output."""
    while True:
        # First, parse the access log file
        await parse_log_file(log_file, connected_listeners, activity_window, log_regex)

        # Then fetch and parse Icecast XML data for each stream
        for stream_name, url in ICESTATS_URLS.items():
            xml_content = await fetch_icestats_data(url, ICESTATS_USERNAME, ICESTATS_PASSWORD)
            await parse_icestats_xml(xml_content, stream_name, connected_listeners)

        update_listener_status(connected_listeners, activity_window, refresh_interval)
        output_data = generate_output(connected_listeners, output_file)

        try:
            with open(output_file, 'w') as f:
                json.dump(output_data, f, indent=4)  # Pretty-printed JSON
            print(f"Output written to {output_file}")
        except Exception as e:
            print(f"Error writing output file: {e}")

        send_to_api(output_data, api_endpoint, api_username, api_password)  # Send the data
        await asyncio.sleep(refresh_interval)  # Check access.log every {refresh_interval} seconds


if __name__ == "__main__":
    asyncio.run(main_loop())
