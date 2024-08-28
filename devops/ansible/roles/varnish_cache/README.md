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
varnish_cache_version: 7.5
# Define the varnish listening port
varnish_cache_listening_port: 80
# Define the varnish malloc size
varnish_cache_malloc_size: 2g
varnish_cache_vcl_host: "127.0.0.1"
#webserver port
varnish_cache_existing_webserver_vcl_port: 8080
# 
varnish_cache_vcl_conf_files_path: templates/conf/*
varnish_cache_default_vcl_file: root.vcl
  
  ```
Varnishadm labeling.
--------------------

- vcl file name with prefix `label_` will be used as a label for the vcl file. Avoid using whitespaces in the vcl file name.

Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

    - hosts: servers
      roles:
         - varnish_cache

