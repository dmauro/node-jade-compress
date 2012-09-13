node-jade-compress
==================

An asynchronous Javascript/Coffeescript &amp; CSS/SASS compressor for the Jade templating engine.

DEPENDENCIES:
coffee-script, connect, express, jade, mime, uglify-js, sqwish

How does it work?

Two filters: compress_js and compress_css are added to the Jade filter list. You can supply the js
filter with either .js or .coffee local files, and the css filter with either .css or .scss local files.
When the template is rendered, it simply creates a hash based on the filenames, and points them at
a /cache directory. Any .js or .css requests to that directory are expected to be hashes, so we then
look up what file cache is associated with that hash, check the mtime of each file vs the time the
cache was created and decide if we need to regenerate the cache.

USAGE EXMAPLES:

IN JADE:
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

The filters will look in following directories for the files:
js      : "#{specified_root_dir}/js"
css     : "#{specified_root_dir}/css"
coffee  : "#{specified_root_dir}/coffee"
sass    : "#{specified_root_dir}/sass"

And will store caches in:
js      : "#{specified_root_dir}/js/cache"
css     : "#{specified_root_dir}/css/cache"

IN YOUR APP:
(example in Coffee)
    express = require 'express'
    coffee = require 'coffee-script'
    compress = require 'node-jade-compress'
    app = express.createServer()
    app.configure(->
        app.use express.logger()
        app.use express.bodyParser()
        app.use express.cookieParser()
        app.use express.session {secret : 'scry', store : session_store}
        app.use app.router
        app.use express.static "#{__dirname}/static"
    )
    app.set 'view engine', 'jade'
    app.set 'view options', {layout: false}
    compress.init __dirname
    compress.views_init app

You supply the views_init function with your express app, which should
be using Jade as the view engine of course (it's the Express default).


PROS:
* This is asynchronous. It will not generate a cache while rendering the template.

* You can combine .js/.coffee files and .css/.scss in a single compress_js or compress_css filter.

* In a dev environment, this will not minify and compress the Javascript, but will run coffee for you and
  give back the individual files for better debugging.

CONS:
* When the cache is invalidated, a new one won't be generated until a user visits, so the response
  time for that user to receive the .js/.css file will be much slower.

* I haven't tested this in a proper production environment. It could probably use a lot of help.

* We have to hardcode any includes we want to use in any of the SASS files. In the intereste of speed
  we can't look at every file, so "vars" and "mixins" have been hardcoded for now.


TODOs:
* Module testing
* Add support for non-local files in compress filters.
* Handle someone requesting a cache file while it's being created.
* Put hashes in a db, allow user to supply a store.
* Allow user to specify which @imports are hardcoded.
* Report SASS errors when compiling
