node-jade-compress
==================

An asynchronous Javascript/Coffeescript and CSS/SASS compressor for the Jade templating engine.

How does it work?
-----------------

Two custom jade filters are added to jade: compress_js and compress_css. These can be used in your
jade templates by including a list of .coffee/.js and .scss/.css files respectively for each filter.
When the template is rendered, a hash is created based on those filenames and the hash/files/timestamp
relationship is remembered. The template renders a script or style tag pointing the user to a cache
directory for their .js or .css file. Any requests made to the cache directory are intercepted to 
check if the compressed file is stale, and if not the cached file will be served up. A cron job runs
that checks the files to see if any caches are stale to prevent users from having to wait for
stale caches to be regenerated.

How do I use it?
----------------

### In your Jade template: ###
```jade
    block extra_css
        :compress_css
            normalize.css
            defaults.scss
            font.css
            game.scss

    block extra_javascript
        include game/_game_js
        :compress_js
            game/main.coffee
            socket.io.js
            chat_client.coffee
```

The filters will look in following directories for the files:  
js      : "#{specified_root_dir}/js"  
css     : "#{specified_root_dir}/css"  
coffee  : "#{specified_root_dir}/coffee"  
sass    : "#{specified_root_dir}/sass"  

And will store caches in:  
js      : "#{specified_root_dir}/js/cache"  
css     : "#{specified_root_dir}/css/cache"  

### In your app: ###
```CoffeeScript
    express = require 'express'
    compress = require 'node-jade-compress'
    app = express.createServer()
    app.set 'view engine', 'jade'
    compress({app : app})
```
When calling node-jade-compress, you must supply it with a settings object.
It needs at least to have a reference to your Express server, but can also have any of these
optional settings (sorry these aren't well documented yet):

    jade = # Defaults to require 'jade'
    root_dir # Defaults to process.cwd()
    js_dir # Defaults to "js"  
    coffee_dir # Defaults to "coffee"
    css_dir # Defaults to "css"
    sass_dir # Defaults to "sass"
    cache_dir # Defaults to "cache"
    js_url # Defaults to "/js/cache"
    css_url # Defaults to "/js/cache"
    sass_imports # Defaults to []
    cleanup_cron # Defaults to '00 00 01 * * *'
    regen_cron = # Defaults to '00 01 * * * *'

Pros and Cons
-------------

PROS:
* This is asynchronous. It will not generate a cache while rendering the template.
* You can combine .js/.coffee files and .css/.scss in a single compress_js or compress_css filter.
* In a dev environment, this will not minify and compress the Javascript, but will run coffee for
you and give back the individual files for better debugging.

CONS:
* Very early, still needs a lot of work.
* Could use some testing.

TODOs:
* Module testing
* Add support for non-local files in compress filters, maybe? (use HEAD request)
* When we create a hash, we should check for imports and add them to the filenames automatically
