node-jade-compress
==================
### An asynchronous JS/CSS compressor with CoffeeScript and Sass support ###

Node-jade-compress provides you with jade template filters that allow you to easily
concatenate and minify/uglify your scripts and styles without an extra build step, and with
support for CoffeeScript and Sass.

NOTE: This currently requires sass to be installed to work. I'm waiting on a bugfix in the node-sass
plugin and then I can drop this requirement.

How does it work?
-----------------

In case you're wondering how this can be asynchronous when jade templates are rendered synchronously,
here's a quick breakdown of how it works:

Two custom jade filters are added to jade: compress_js and compress_css. These can be used in your
jade templates by including a list of .coffee/.js and .scss/.css files respectively for each filter.
When the template is rendered, a hash is created based on those filenames and the hash/filenames
relationship is stored. The template renders a script or style tag pointing the user to a cache
directory for the .js or .css file, that url includes the hash and the timestamp. Any requests made
to a cache directory are intercepted to check if the compressed file is stale, and if not the cached
file will be served up.

And yes this will also automatically check your sass imports to see if they have been modified to
invalidate any caches that rely on them.


How do I use it?
----------------

### Install: ###
```
    $ npm install node-jade-compress
```

### In your Jade template: ###
```jade
    :compress_css
        foo.css
        bar.scss
        baz/qux.css

    :compress_js
        foo.coffee
        bar/baz.js
```
(There is also a :compress_js_async filter which will load all of your scripts asynchronously and in
the correct order. If you use this in development though, it will concat and uglify all of your JS,
so I recommend developing with :compress_js and then moving to :compress_js_async until I get this
worked out a little better.)

### In your app: ###
```CoffeeScript
    express = require 'express'
    compress = require 'node-jade-compress'
    app = express.createServer()
    app.set 'view engine', 'jade'
    compress.init({app : app, jade})
```

Optional Settings
-----------------
When calling node-jade-compress, you must supply it with a settings object.
It needs at least to have a reference to your Express server, and you can also
use any of these optional settings:

    root_dir        # Defaults to process.cwd()
    js_dir          # Defaults to "js"  
    coffee_dir      # Defaults to "coffee"
    css_dir         # Defaults to "css"
    sass_dir        # Defaults to "sass"
    cache_dir       # Defaults to "cache"
    js_url          # Defaults to "/js"
    css_url         # Defaults to "/css"
    js_cache_url    # Defaults to "#{js_url}/cache"
    css_cache_url   # Defaults to "#{css_url}/cache"
    regen_cron      # Defaults to '*/10 * * * * *' or every ten minutes
    cleanup_cron    # Defaults to '00 00 00 * * 0' or once per week

### Directories ###
The filters will look in following directories for the files by default:
```
js      : "#{root_dir}/#{js_dir}"
css     : "#{root_dir}/#{css_dir}"
coffee  : "#{root_dir}/#{coffee_dir}"
sass    : "#{root_dir}/#{sass_dir}"
```

And will store caches in:
```
js      : "#{root_dir}/#{js_dir}/#{cache_dir}"
css     : "#{root_dir}/#{css_dir}/#{cache_dir}"
```

Cached file requests will point towards:
```
js      : "#{js_cache_url}"
css     : "#{css_cache_url}"
```

And you can automatically convert coffeescript and and sass files on the fly by visiting:
```
coffee  : "#{js_url}"
sass    : "#{css_url}"
```
(You should only use this for aiding in development, don't point users to these urls as they
are set to expire instantly and won't be cached properly)

### Cron ###
Two cron jobs will be spawned, one to look for invalid caches that need to be regenerated, and
the other to clear out caches that are no longer in use. 

Regen cron: This is going to call fs.stat on every file found in a compress filter. If the file
has been modified since the cache file was last modified, that cache will be regenerated. If a 
user tries to get a stale cache, it will be regenerated, keeping that user waiting a little longer.
So ideally this will run frequently enough to prevent any users from having to wait for cache
generation. (Note: this will not generate caches that haven't been generated at least once)

Cleanup cron: This will remove any cached files that haven't been accessed since the last time this
ran. At the default of once per week, that would mean that any files not accessed weekly would be
deleted.

Pros and Cons
-------------

PROS:  
* This is asynchronous. It will not generate a cache while rendering the template, but will wait for the cron job to run or for a user to request the cached file and then generate it asynchronously.  
* You can combine .js &amp; .coffee files and .css &amp; .scss in a single compress_js or compress_css filter.  
* In a dev environment, this will not minify and compress the Javascript, but will run coffee for you and give back the individual files for better debugging.  

CONS:  
* I haven't actually tried this out under heavy load.  

TODO:
-----
* Replace regen cron with fs.watch on coffee and sass dirs.
* Allow restore by supplying hash/filenames dictionary (run regen function immediately after).
