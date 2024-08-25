Varnish Cache
=========

Enable varnish cache on the server (Nginx).
### Basic Varnish commands
```bash
# Check the status of varnish
sudo systemctl status varnish
# Start varnish
sudo systemctl start varnish
# Stop varnish
sudo systemctl stop varnish
# Restart varnish
sudo systemctl restart varnish
# Reload varnish
sudo systemctl reload varnish
# admin
varnishadm

```

Role Variables
--------------
```yaml
varnish_cache_listening_port: 80
varnish_cache_malloc_size: 2g
varnish_cache_vcl_host: "127.0.0.1"
varnish_cache_existing_webserver_vcl_port: 8080
  ```
Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

    - hosts: servers
      roles:
         - varnish_cache

