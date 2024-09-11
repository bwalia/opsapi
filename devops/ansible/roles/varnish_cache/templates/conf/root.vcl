vcl 4.1;

backend default {
    .host = "{{ varnish_cache_vcl_host }}";
    .port = "{{ varnish_cache_existing_webserver_vcl_port }}";
}
  sub vcl_backend_response {
       
        set beresp.ttl = 1h;

        
        set beresp.grace = 1w;
    }
