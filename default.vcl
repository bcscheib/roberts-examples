import std;

backend default {
    .host = "127.0.0.1";
    .port = "8080";
}


backend s3 {
  .host = "s3.amazonaws.com";
  .port = "80";
}

backend web_ssl {
  .host = "127.0.0.1";
  .port = "444";
}


acl purge {
    "localhost";
    "127.0.0.1";
}

sub vcl_pipe {
        # Note that only the first request to the backend will have
 
        set req.http.connection = "close";
}
 
sub vcl_recv {
    call normalize_req_url; #force strip query strings
    if (req.http.host == "discoverhawaiitours.com") {
        set req.http.Location = "http://www.discoverhawaiitours.com" + req.url; #force immediate -> www 301
    	  error 750 "Permanently moved";
    }
  # always pass through POST requests and those with basic auth
  if (req.http.Authorization || req.request == "POST") {
      std.log("DEV: passed becuase of auth on: " + req.url);
      return (pass);
  }

  #default pass throughs
  if ( (req.url ~ "^/thanks") ||
       (req.url ~ "^/redirect") || 
       (req.url ~ "^/dispatch") || 
       (req.url ~ "^/reservation") || 
       (req.url ~ "^/checkout") || 
	   (req.url ~ "^/thank-you") || 
       (req.url ~ "^/apc.php") ||
       (req.url ~ "^/apc_clear.php")
   ) {
    std.log("DEV: passed for cart on URL: " + req.url + "and backend was: " + req.backend);
  	return(pass);
  }
  # admin users always miss the cache
  else if( req.url ~ "^/wp-(login|admin)"){ # || req.http.Cookie ~ "wordpress_logged_in_" ){
    std.log("DEV: passed becuase of wordpress logged in: " + req.url);
    return (pass);
  }

else if ((req.request == "GET" || req.request == "HEAD") && req.url ~ "\.(css|gif|ico|jpg|jpeg|js|png|swf|txt|gzip)$") {
      unset req.http.cookie;
      unset req.http.cache-control;
      unset req.http.pragma;
      unset req.http.expires;
      unset req.http.etag;
      unset req.http.X-Forwarded-For;
      set req.backend = s3;
      if (req.http.host == "mirror.discoverhawaiitours.com")
      {
        set req.http.host = "mirror.discoverhawaiitours.com";
      } else {
        set req.http.host = "cdn.discoverhawaiitours.com";
      }
#      std.log("DEV: looking up an asset in s3 for: " + req.url + " my cdn: " + req.http.host);
      return(lookup);
  }
else if (req.request == "GET" || req.request == "HEAD") {
      unset req.http.cookie;
      unset req.http.cache-control;
      unset req.http.pragma;
      unset req.http.expires;
      unset req.http.etag;
      unset req.http.X-Forwarded-For;
	  if(req.url == "/" || req.url ~ "^\/index.htm"){
	    std.log("DEV: rendering root path from url: " + req.url);
		set req.url = "/static/index.html";
	  }else if(req.url == "/sitemap.xml"){
	    set req.url = "/static/sitemap.xml";
	  }else if(req.url ~ "blog\/feed"){
	    set req.url = "/static/blog/feed.xml";
	  }
	  else{
	      set req.url = regsub(req.url, "^([\/\w_-]+)$", "/static\1");
	      if(req.url !~ "\.html"){
	        set req.url = regsub(req.url, "(\/)?$", ".html");
	      }
	  }
    std.log("DEV: looking up in s3 for: " + req.url);
    set req.backend = s3;
    if (req.http.host == "mirror.discoverhawaiitours.com")
    {
      set req.http.host = "mirror.discoverhawaiitours.com";
    } else {
      set req.http.host = "cdn.discoverhawaiitours.com";
    }

#	std.log("DEV GET: looking up an asset in s3 for: " + req.url + " my cdn: " + req.http.host);

      return(lookup);
  }

else{
      std.log("DEV: passed by default last else block on: " + req.url + " with request type: " + req.request);
      return(pass);
  }



    # Handle compression correctly. Different browsers send different
    # "Accept-Encoding" headers, even though they mostly support the same
    # compression mechanisms. By consolidating compression headers into
    # a consistent format, we reduce the cache size and get more hits.
    # @see: http:// varnish.projects.linpro.no/wiki/FAQ/Compression
    if (req.http.Accept-Encoding) {
        if (req.http.Accept-Encoding ~ "gzip") {
            # If the browser supports it, we'll use gzip.
            set req.http.Accept-Encoding = "gzip";
        }
        else if (req.http.Accept-Encoding ~ "deflate") {
            # Next, try deflate if it is supported.
            set req.http.Accept-Encoding = "deflate";
        }
        else {
            # Unknown algorithm. Remove it and send unencoded.
            unset req.http.Accept-Encoding;
        }
    }
 
    # Set client IP
    if (req.http.x-forwarded-for) {
        set req.http.X-Forwarded-For =
        req.http.X-Forwarded-For + ", " + client.ip;
    } else {
        set req.http.X-Forwarded-For = client.ip;
    }
 
    # Check if we may purge (only localhost)
    if (req.request == "PURGE") {
        if (!client.ip ~ purge) {
            error 405 "Not allowed.";
        }
        return(lookup);
    }
 
    if (req.request != "GET" &&
        req.request != "HEAD" &&
        req.request != "PUT" &&
        req.request != "POST" &&
        req.request != "TRACE" &&
        req.request != "OPTIONS" &&
        req.request != "DELETE") {
            # /* Non-RFC2616 or CONNECT which is weird. */
            return (pipe);
    }
 
    if (req.request != "GET" && req.request != "HEAD") {
        # /* We only deal with GET and HEAD by default */
        return (pass);
    }
 
    # Remove cookies set by Google Analytics (pattern: '__utmABC')
    if (req.http.Cookie) {
        set req.http.Cookie = regsuball(req.http.Cookie,
            "(^|; ) *__utm.=[^;]+;? *", "\1");
        if (req.http.Cookie == "") {
            remove req.http.Cookie;
        }
    }
 
    
 
    # Do not cache these paths
    if (req.url ~ "^/wp-cron\.php$" ||
        req.url ~ "^/xmlrpc\.php$" ||
        req.url ~ "^/wp-admin/.*$" ||
        req.url ~ "^/wp-includes/.*$" ||
        req.url ~ "\?s=") {
            return (pass);
    }
 
    # Define the default grace period to serve cached content
    set req.grace = 30s;
 
    # By ignoring any other cookies, it is now ok to get a page
    unset req.http.Cookie;
    return (lookup);
}
 
sub vcl_fetch {
    # remove some headers we never want to see
    unset beresp.http.Server;
    unset beresp.http.X-Powered-By;

	unset beresp.http.X-Amz-Id-2;
  unset beresp.http.X-Amz-Meta-Group;
  unset beresp.http.X-Amz-Meta-Owner;
  unset beresp.http.X-Amz-Meta-Permissions;
  unset beresp.http.X-Amz-Request-Id;

  set beresp.ttl = 1w;
  set beresp.grace = 30s;
 
	if (req.url ~ "html$") {
                set beresp.do_gzip = true;
        }

    # only allow cookies to be set if we're in admin area
    if( beresp.http.Set-Cookie && req.url !~ "^/wp-(login|admin)" ){
        unset beresp.http.Set-Cookie;
    }

    if((req.request == "GET" || req.request == "HEAD") && ((req.url ~ "\?action=warp_search") ||
       (req.url ~ "\?action=activityajax-submit") || (req.url ~ "\?a=") || (req.url ~ "\?s=") || (req.url ~ "\?template=")))
      {
		std.log("delivered: " + req.url);
		return(deliver);
	}
 
    # don't cache response to posted requests or those with basic auth
    # if ( req.request == "POST" || req.http.Authorization ) {
    #         std.log("DEV: beresp return hit for pass post: " + req.url);
    #         return (hit_for_pass);
    #     }
    
    
 
    if (req.restarts > 0 || (req.url ~ "^/checkout") || (req.url ~ "^/thank-you") || (req.url ~ "^/redirect") || (req.url ~ "^/dispatch") || (req.url ~ "^/reservation") ||
         (req.url ~ "^/apc.php") ||
         (req.url ~ "^/apc_clear.php")
     ) {
      std.log("DEV: passed for car on URL on fetch: " + req.url);
    	return(hit_for_pass);
    }

    if ( req.backend == s3 && beresp.status != 200 ) {
        set req.backend = default;
        set req.url = regsub(req.url, "\/static", "");
        set req.url = regsub(req.url, "\.html", "");
        std.log("DEV: s3 beresp return not 200 sending to nginx as : " + req.url);
        return (restart);
    }
 
    # only cache status ok
    if ( beresp.status != 200 ) {
		 std.log("DEV: beresp return not 200: " + req.url);
        return (hit_for_pass);
    }
 
    # If our backend returns 5xx status this will reset the grace time
    # set in vcl_recv so that cached content will be served and 
    # the unhealthy backend will not be hammered by requests
    if (beresp.status == 500) {
	    std.log("DEV: beresp return restart: " + req.url);
        set beresp.grace = 60s;
        return (restart);
    }
 
    # GZip the cached content if possible
    if (beresp.http.content-type ~ "text") {
        set beresp.do_gzip = true;
    }
 
    # if nothing abovce matched it is now ok to cache the response
    set beresp.ttl = 24h;
    std.log("DEV: beresp delivered it with status" +  beresp.status + ": " + req.url);
    return (deliver);
}
 
sub vcl_deliver {
    # remove some headers added by varnish
    unset resp.http.Via;
    unset resp.http.X-Varnish;
     std.log("deliver: " + req.url);
}
 
sub vcl_hit {
    # Set up invalidation of the cache so purging gets done properly
std.log("DEV: hit: " + req.url);
    if (req.request == "PURGE") {
        purge;
        error 200 "Purged.";
    }
    return (deliver);
}
 
sub vcl_miss {
std.log("DEV: miss: " + req.url);
    # Set up invalidation of the cache so purging gets done properly
    if (req.request == "PURGE") {
	std.log("DEV: purging! " + req.url);
        purge;
        error 200 "Purged.";
    }
    return (fetch);
}
 
sub vcl_error {
	if (obj.status == 503) {
	    std.log("was a 503 error");
                # set obj.http.location = req.http.Location;
                set obj.status = 404;
        set obj.response = "Not Found";
                return (deliver);
    }
    
    if (obj.status == 750) {
       		set obj.http.location = req.http.Location;
       		set obj.status = 301;
       		return (deliver);
       	}
}

sub vcl_hash {
	if(req.url ~ "^/thanks") {
    		set req.http.X-Sanitized-URL = req.url;
    		set req.http.X-Sanitized-URL = regsub(req.http.X-Sanitized-URL, "\?sessionid=[A-Za-z0-9]+", "");
std.log("DEV hash: " + req.http.X-Sanitized-URL);
  		hash_data(req.http.X-Sanitized-URL);
	} else {
  		hash_data(req.url);
	}
  	hash_data(req.http.host);
	return (hash);
}

#normalize cache query string requests
sub normalize_req_url {
    if(req.url !~ "(\?|&)(cart_action|get_hotel_name|s|page_num|a+|mr:[A-z]+)="){
      set req.url = regsuball(req.url, "\?([A-z]+)=?[-{}%.-_A-z0-9]+&?", "");
    }
    
    set req.url = regsub(req.url, "(\?&?)$", ""); #get rid of trailing characters
}