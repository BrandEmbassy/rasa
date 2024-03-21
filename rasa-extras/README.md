# RASA Extras

Custom extensions for RASA.

RASA depends on tensorflow which supports only Python 3.6.

## Development

For development purposes it is sufficient to install RASA without dependencies

```shell
pip install --no-deps -r requirements-dev.txt
pip install --no-deps -r requirements.txt
```

**DO NOT PUT Rasa dependency into requirements.txt**

## Extensions

To use RASA extensions in RASA docker container, extract distribution package of this repository in `/app/extras` path.

### TrackerStore ExtraRedisTrackerStore

This tracker store enables rich configuration of Redis client library, incl. timeouts and TCP keepalive.

Additional configuration parameters:

- `cluster`: bool, redis operate in cluster mode or not
- `scan_count`: int, preferred number of keys to search per cursor iteration
- `retry_on_timeout`: bool, flag whether Redis operation should be retried in case of network timeout
- `health_check_interval`: int, perform health check `PING` command just before a command is executed if the 
  underlying connection has been idle for more than `health_check_interval` seconds
- `socket_connect_timeout`: float, connection timeout in seconds
- `socket_keepalive`: bool, flag whether TCP keepalive should be enabled 
- `socket_keepalive_options`: dict, additional configuration of TCP connection, used if `socket_keepalive` is enabled

#### TCP keepalive

The TCP keepalive configuration is OS dependent.

**Linux example:** After `TCP_KEEPIDLE` seconds of being idle, send keepalive packet every `TCP_KEEPINTVL` seconds.
Close the connection after `TCP_KEEPCNT` fails.

```yaml
tracker_store:
    type: extras.trackerstore.ExtraRedisTrackerStore
    ...
    socket_keepalive: true
    socket_keepalive_options:
      TCP_KEEPIDLE: 5
      TCP_KEEPINTVL: 5
      TCP_KEEPCNT: 3
```

**OSX example:** Send keepalive packet every `TCP_KEEPALIVE` seconds.

```yaml
tracker_store:
    type: extras.trackerstore.ExtraRedisTrackerStore
    ...
    socket_keepalive: true
    socket_keepalive_options:
      TCP_KEEPALIVE: 5
```
