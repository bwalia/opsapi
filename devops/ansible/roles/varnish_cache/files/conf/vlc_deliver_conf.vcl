# This is an example VCL file for Varnish.
#
# It does not do anything by default, delegating control to the
# builtin VCL. The builtin VCL is called when there is no explicit
# return statement.
#
# See the VCL chapters in the Users Guide at https://www.varnish-cache.org/docs/
# and https://www.varnish-cache.org/trac/wiki/VCLExamples for more examples.

# Marker to tell the VCL compiler that this VCL has been adapted to the
# new 4.0 format.


#http://s3.eu-west-2.amazonaws.com/origin.wcdn.weshape.dev/index.html

vcl 4.1;

import std;

backend default_backend {
    .host = "127.0.0.1";
    .port = "8080";
#    .probe = {
#        .url = "/index.php";
#        .timeout = 1s;
#        .interval = 5s;
#        .window = 5;
#        .threshold = 3;
#    }
}

sub vcl_miss {
        set req.http.x-cache = "miss";
}

sub vcl_pass {
        set req.http.x-cache = "pass";
}


sub vcl_recv {

     #Goodbye incoming cookies:
     unset req.http.Cookie;

set req.http.x-cache = "recv";

        set req.http.Host = "int.brahmstra.org";
        set req.backend_hint = default_backend;

}

sub vcl_hit {
  set req.http.x-cache = "hit";

    #set beresp.http.cache-control = "public, max-age=600";
    #unset beresp.http.server;

}

sub vcl_miss {
  set req.http.x-cache = "miss";
}

sub vcl_pass {
  set req.http.x-cache = "pass";
}

sub vcl_pipe {
  set req.http.x-cache = "pipe uncacheable";
}

#sub vcl_fetch is not replaced by vcl_backend_response



sub vcl_backend_error {
#return (synth(502));

}

sub vcl_synth {
  set req.http.x-cache = "vcl synth";
    set resp.http.Content-Type = "text/html; charset=utf-8";
    set resp.http.Retry-After = "5";
    synthetic( {"<!DOCTYPE html>
<html>
  <head>
    <title>"} + resp.status + " " + resp.http.reason + {"</title>
  </head>
  <body>
    <h1>Error "} + resp.status + " " + resp.http.reason + {"</h1>
    <p>"} + resp.http.reason + {"</p>
    <h3>XGuru Meditation:</h3>
    <p>XID: "} + req.xid + {"</p>
    <hr>
    <p>Varnish cache server www.solariacdn.com</p>
  </body>
</html>
"} );
    return (deliver);
}

# That's all you need, but you might want to start adjusting cache duration
# too! You can do that by emitting "Cache-Control: s-maxage=123" from your
# backend server, telling Varnish to cache for 123 seconds. That requires 0
# configuration, but the following snippet removes "s-maxage" from the
# response before it is sent to the client, so as not to confuse other
# proxy servers between you and the client.
sub strip_smaxage {
  # Remove white space
  set beresp.http.cache-control = regsuball(beresp.http.cache-control, " ","");
  # strip s-maxage - Varnish has already used it
  set beresp.http.cache-control = regsub(beresp.http.cache-control, "s-maxage=[0-9]+\b","");
  # Strip extra commas
  set beresp.http.cache-control = regsub(beresp.http.cache-control, "(^,|,$|,,)", "");
}


sub vcl_backend_fetch
{




return (fetch);

}


# This just calls the above function at the appropriate time.
sub vcl_backend_response {

  call strip_smaxage;

#set beresp.stale_if_error = 1w;
set beresp.grace = 1w;

set beresp.ttl = 1h;

}




sub vcl_deliver {

  if (obj.uncacheable) {
    set req.http.x-cache = req.http.x-cache + " uncacheable" ;
  } else {
    set req.http.x-cache = req.http.x-cache + " cached" ;
  }
  # uncomment the following line to show the information in the response

  #unset some of the headers which are security issue by exposing backend apps the version numbers

  set resp.http.x-cache = req.http.x-cache;
  set resp.http.x-origin-hostname = req.http.Host;
  set resp.http.x-vcl-type = "default";

  return (deliver);
}



# You can read more about control Varnish through headers at
# https://varnishfoo.info/chapter-2.html