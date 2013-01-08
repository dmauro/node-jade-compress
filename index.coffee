#!/usr/bin/env coffee

crypto = require 'crypto'
fs = require 'fs'
cp = require 'child_process'
mime = require 'mime'
uglify = require 'uglify-js'
sqwish = require 'sqwish'
cron = require 'cron'
utils = require('connect').utils
paths = {}
test_helper = {
    files_generated : 0
}

##########################
# Hash keyed dictionaries:
##########################
# Tracks all filenames in a given hash
file_groups = {}
# Used to mark that we are currently compressing a hash
processing = {}
# Tracks requests waiting for compressed file to be generated
requests_waiting_on_compress = {}

create_hash = (filenames) ->
    md5 = crypto.createHash 'md5'
    for filename in filenames
        md5.update filename
    hash = md5.digest 'hex'
    return hash
    return md5.digest 'hex'

serve_file = (req, res, filepath, is_fresh = false) ->
    fs.stat filepath, (err, stat) ->
        res.setHeader 'Date', new Date().toUTCString()
        res.setHeader 'Cache-Control', 'public, max-age=0'
        res.setHeader 'Last-Modified', stat.mtime.toUTCString()
        res.setHeader 'ETag', utils.etag stat
        filetype = mime.lookup filepath
        charset = mime.charsets.lookup filetype
        res.setHeader 'Content-Type', "#{filetype};charset=#{charset}"
        res.setHeader 'Accept-Ranges', 'bytes'
        # Check if we should just 304 before sending the file
        unless is_fresh
            if utils.conditionalGET req
                if !utils.modified req, res
                    utils.notModified res
                    return
        stream = fs.createReadStream filepath;
        stream.pipe res

mangle_js = (data) ->
    ast = uglify.parser.parse data
    ast = uglify.uglify.ast_mangle ast
    ast = uglify.uglify.ast_squeeze ast
    data = uglify.uglify.gen_code ast
    return data

coffee_to_js = (stream, callback, filepath="") ->
    coffee = cp.spawn "coffee", ["-sp "]
    failure = false
    is_enoent = false
    spool = ""
    coffee.stderr.on 'data', (data) ->
        error_txt = data.toString 'ascii'
        if error_txt.indexOf("ENOENT") > -1
            is_enoent = true
            return callback null
        else if process.env.ENV_VARIABLE is "development"
            spool += new Buffer 'alert(\'COFFEE ERROR: ' + error_txt.split("\n")[0] + ' - FILEPATH: ' + filepath + '\');', 'ascii'
        failure = true
    coffee.stdout.on 'data', (data) ->
        spool += data
    coffee.stdout.on 'end', ->
        callback spool unless is_enoent
    stream.pipe coffee.stdin

sass_to_css = (filepath, callback) ->
    spool = ""
    is_enoent = false
    sass = cp.spawn "sass", [filepath]
    sass.stderr.on 'data', (data) ->
        error_txt = data.toString 'ascii'
        if error_txt.indexOf("ENOENT") > -1
            is_enoent = true
            return callback null
        else if process.env.ENV_VARIABLE is "development"
            # CSS trick to get the error on screen
            spool += "body:before{content:\"#{error_txt.replace(/"/g, "\\\"")}\";font-size:16px;font-family:monospace;color:#900;}"
            spool += error_txt
    sass.stdout.on 'data', (data) ->
        # Sass puts in newlines, so let's remove those
        data = data.toString 'ascii'
        data = data.replace /\r\n|\r+|\n+/, ''
        spool += data
    sass.stdout.on 'end', ->
        sass.kill 'SIGTERM'
        callback spool unless is_enoent
        
get_file_extension = (filename) ->
    a = filename.split "."
    return a[a.length - 1]

create_file = (hash, filetype, res) ->
    processing[hash] = true
    filenames = file_groups[hash]
    spool = []
    i = 0
    for index in [0...filenames.length]
        filename = filenames[index]
        spool.push index
        ((callback, index, res, filename, max) ->
            file_not_found = ->
                if requests_waiting_on_compress[hash]
                    delete requests_waiting_on_compress[hash]
                return res.send 404 if res

            done_parsing = (data) ->
                # Ensure we write the data in the order the files were listed
                spool[index] = data
                i++
                callback() if i >= max
                
            extension = get_file_extension filename
            filepath = null
            if extension in ["js", "css"]
                filepath = "#{paths['file_standard'][filetype]}/#{filename}"
            else if extension in ["coffee", "scss"]
                filepath = "#{paths['file_abstract'][filetype]}/#{filename}"
                
            # Deal with COFFEE and JS files
            if filetype is "js"
                stream = fs.createReadStream filepath
                stream.pause()
                stream.on 'error', (data) ->
                    if data.toString('ascii').indexOf('ENOENT') > -1
                        return file_not_found()
                if extension is "js"
                    js_spool = ""
                    stream.on 'data', (data) ->
                        js_spool += data.toString 'ascii'
                    stream.on 'end', ->
                        done_parsing js_spool
                else if extension is "coffee"
                    coffee_to_js stream, (data) ->
                        unless data?
                            return file_not_found()
                        done_parsing data.toString 'ascii'
                stream.resume()

            # Deal with SCSS and CSS files
            else if filetype is "css"
                if extension is "css"
                    fs.readFile filepath, 'ascii', (err, data) ->
                        if err and err.code is "ENOENT"
                            return file_not_found()
                        throw err if err
                        done_parsing data
                else if extension is "scss"
                    sass_to_css filepath, (data) ->
                        unless data?
                            return file_not_found()
                        done_parsing data
        )(->
            filepath = "#{paths['cache'][filetype]}/#{hash}.#{filetype}"
            data = ""
            for chunk in spool
                data += chunk
            if filetype is "js"
                data = mangle_js data
            if filetype is "css"
                data = sqwish.minify data
            fs.writeFile filepath, data, 'ascii', (err) ->
                # Serve this file up to anyone else waiting for it
                delete processing[hash]
                if requests_waiting_on_compress[hash]
                    for request in requests_waiting_on_compress[hash]
                        serve_file request.req, request.res, filepath, true
                    delete requests_waiting_on_compress[hash]
                test_helper.files_generated += 1
        , index, res, filename, filenames.length)

create_then_serve_file = (req, res, filetype, filenames) ->
    hash = create_hash filenames
    # Put us in queue to receive file once its been created
    requests_waiting_on_compress[hash] = [
        req : req
        res : res
    ]
    create_file hash, filetype, res

cache_is_stale = (cache_mtime, filenames, callback) ->
    i = filenames.length
    is_done = false
    for filename in filenames
        extension = get_file_extension filename
        path = null
        if filename.substr(0, 4) is "http"
            # TODO: non-local files over http
        else
            # For local files
            if extension is "js"
                path = "#{paths['file_standard']['js']}/#{filename}"
            else if extension is "css"
                path = "#{paths['file_standard']['css']}/#{filename}"
            else if extension is "coffee"
                path = "#{paths['file_abstract']['js']}/#{filename}"
            else if extension is "scss"
                path = "#{paths['file_abstract']['css']}/#{filename}"
            fs.stat path, (err, stat) ->
                throw Error err if err
                i--
                if +stat.mtime > +cache_mtime
                    callback true unless is_done
                    is_done = true
                callback false if i is 0 and !is_done
        
send_response = (req, res, filetype) ->
    filenames = file_groups[req.params.hash]
    return res.send 404 unless filenames
    filepath = "#{paths['cache'][filetype]}/#{req.params.hash}.#{filetype}"
    fs.stat filepath, (err, cache_stat) ->
        if not err
            cache_is_stale cache_stat.mtime, filenames, (is_stale) ->
                if is_stale
                    create_then_serve_file req, res, filetype, filenames
                else
                    serve_file req, res, filepath
        else if err.code is "ENOENT"
            # This file has not been generated yet
            # Put us in the queue to receive when ready
            if processing[req.params.hash]
                requests_waiting_on_compress[req.params.hash].push(
                    req : req
                    res : res
                )
            else
                create_then_serve_file req, res, filetype, filenames
        else
            throw err

test_helper.regen_cron = regen_stale_caches = ->
    console.log "regen", file_groups
    # Called by cron so that your users don't have to wait
    for own hash, filenames of file_groups
        continue unless filenames
        ((hash, filenames) ->
            # Guess filetype of hash from filenames
            extension = get_file_extension filenames[0]
            if extension in ["css", "scss"]
                filetype = "css"
            else
                filetype = "js"
            filepath = "#{paths['cache'][filetype]}/#{hash}.#{filetype}"
            fs.stat filepath, (err, cache_stat) ->
                if err
                    if err.code is "ENOENT"
                        # This hash doesn't have a file, and it is not processing
                        # so we should remove it from file_groups
                        return delete file_groups[hash]
                    else
                        throw err
                    return
                cache_is_stale cache_stat.mtime, filenames, (is_stale) ->
                    return unless is_stale
                    test_helper.cron.regenerated += 1
                    create_file hash, filetype
        )(hash, filenames)

cron_last_checked = 0
test_helper.clear_cron = clear_old_caches = ->
    # If a hash hasn't been accessed since this was last called, we'll clear it
    i = 0
    for own hash, filenames of file_groups
        continue unless filenames
        i++
        ((hash, filenames) ->
            # Guess filetype of hash from filenames
            extension = get_file_extension filenames[0]
            if extension in ["css", "scss"]
                filetype = "css"
            else
                filetype = "js"
            filepath = "#{paths['cache'][filetype]}/#{hash}.#{filetype}"
            fs.stat filepath, (err, cache_stat) ->
                i--
                if err
                    if err.code is "ENOENT"
                        # This hash doesn't have a file, and it is not processing
                        # so we should remove it from file_groups
                        return delete file_groups[hash]
                    else
                        throw err
                unless +cache_stat.atime > +cron_last_checked
                    # Delete the file and hash
                    fs.unlink filepath, (err) ->
                        test_helper.cron.removed += 1
                        delete file_groups[hash]
                        throw err if err
                cron_last_checked = new Date() if i is 0
        )(hash, filenames)

module.exports = {}

module.exports.test_helper = test_helper

module.exports.init = (settings, callback) ->
    # You must pass in the app
    app = settings.app
    # Everything else is optional
    file_groups = settings.file_groups or {}
    root_dir = settings.root_dir or process.cwd
    js_dir = settings.js_dir or "js"
    coffee_dir = settings.coffee_dir or "coffee"
    css_dir = settings.js_dir or "css"
    sass_dir = settings.sass_dir or "sass"
    cache_dir = settings.cache_dir or "cache"
    js_url = settings.js_url or "/js"
    css_url = settings.css_url or "/css"
    js_cache_url = settings.js_cache_url or "#{js_url}/cache"
    css_cache_url = settings.css_cache_url or "#{css_url}/cache"
    jade = settings.jade or require 'jade'
    sass_imports = settings.sass_imports or []
    cleanup_cron = settings.cleanup_cron or '00 00 01 * * *' # Runs once a day
    regen_cron = settings.regen_cron or '00 01 * * * *' # Runs once an hour
    # Cron Syntax
    # Second(0-59) Minute(0-59) Hour(0-23) DayMonth(1-31) Month(1-12) DayWeek(0-6/Sunday-Saturday)

    paths = {
        cache   : {
            js  : "#{root_dir}/#{js_dir}/#{cache_dir}"
            css : "#{root_dir}/#{css_dir}/#{cache_dir}"
        }
        file_standard   : {
            js  : "#{root_dir}/#{js_dir}"
            css : "#{root_dir}/#{css_dir}"
        }
        file_abstract   : {
            js  : "#{root_dir}/#{coffee_dir}"
            css : "#{root_dir}/#{sass_dir}"
        }
        url     : {
            js  : js_cache_url
            css : css_cache_url
        }
    }
    # Make sure required directories exist
    for name, group of paths
        continue unless name in ['file_standard', 'file_abstract']
        for type, dir of group
            ((dir) ->
                fs.stat dir, (err, cache_stat) ->
                    if err and err.code is "ENOENT"
                        fs.mkdir dir, 0o0755, (err) ->
                            throw err if err
            )(dir)
    # Either create or clear out cache dirs
    # TODO: Don't clear them out, the cron takes care of that now
    for dir in [paths['cache']['js'], paths['cache']['css']]
        ((dir) ->
            fs.stat dir, (err, cache_stat) ->
                if err and err.code is "ENOENT"
                    fs.mkdir dir, 0o0755, (err) ->
                        throw err if err
                else if cache_stat
                    fs.readdir dir, (err, files) ->
                        if files.length > 0
                            for file in files
                                ext = file.split "."
                                continue unless ext[ext.length - 1] in ["js", "css"]
                                fs.unlink "#{dir}/#{file}", (err) ->
                                    throw err if err
        )(dir)

    # Jade filter dependencies
    jade_get_filenames = (data) ->
        data = data.replace /\\n+$/, ''
        filenames = data.split /\\n+/
        return filenames
    
    jade_hash = (data, filetype) ->
        filenames = jade_get_filenames data
        # Force check on SASS dependencies
        for filename in filenames
            extension = get_file_extension filename
            if filetype is "js" and extension not in ["js", "coffee"]
                # Compress JS can only include .js or .coffee files
                return null
            if filetype is "css" and extension not in ["css", "scss"]
                # Compress CSS can only include .css or .scss files
                return null
            if extension is "scss"
                for import_filename in sass_imports
                    import_extension = get_file_extension import_filename
                    if import_extension not in ["scss", "sass"]
                        import_filename += ".scss"
                    filenames.unshift import_filename
                break
        hash = create_hash filenames
        file_groups[hash] = filenames
        return hash

    jade.filters.compress_css = (data) ->
        hash = jade_hash data, "css"
        return "" unless hash
        return "<link rel=\"stylesheet\" href=\"#{paths['url']['css']}/#{hash}.css\">"

    jade.filters.compress_js = (data) ->
        hash = jade_hash data, "js"
        return "" unless hash
        return "<script src=\"#{paths['url']['js']}/#{hash}.js\"></script>"

    # These are mostly just to help looking at your files
    # you should not send your users to these:
    send_with_instant_expiry = (res, data) ->
        res.setHeader 'Date', new Date().toUTCString()
        res.setHeader 'Cache-Control', 'public, max-age=0'
        res.setHeader 'Last-Modified', new Date().toUTCString()
        res.send data

    send_with_js_headers = (res, data) ->
        res.setHeader 'Content-Type', "text/javascript;charset=UTF-8"
        send_with_instant_expiry res, data

    send_with_css_headers = (res, data) ->
        res.setHeader 'Content-Type', "text/css;charset=UTF-8"
        send_with_instant_expiry res, data
        
    app.get "#{paths['url']['js']}/:hash.js", (req, res) ->
        send_response req, res, "js"

    app.get "#{paths['url']['css']}/:hash.css", (req, res) ->
        send_response req, res, "css"

    app.get "#{js_url}/*.coffee", (req, res) ->
        filepath = "#{paths['file_abstract']['js']}/#{req.params[0]}.coffee"
        stream = fs.createReadStream filepath
        stream.pause()
        coffee_to_js stream, (data) ->
            send_with_js_headers res, data
        , filepath
        stream.resume()

    app.get "#{js_url}/*.js", (req, res) ->
        filepath = "#{paths['file_standard']['js']}/#{req.params[0]}.js"
        stream = fs.createReadStream filepath
        stream.pause()
        js_spool = ""
        stream.on 'data', (data) ->
            js_spool += data.toString 'ascii'
        stream.on 'end', ->
            send_with_js_headers res, js_spool
        stream.resume()
        send_response req, res, "css"

    app.get "#{css_url}/*.scss", (req, res) ->
        filepath = "#{paths['file_abstract']['css']}/#{req.params[0]}.scss"
        sass_to_css filepath, (data) ->
            send_with_css_headers res, data

    app.configure "development", ->
        # Don't compress CoffeeScript in development, only convert to JS
        jade.filters.compress_js = (data) ->
            filenames = jade_get_filenames data
            scripts = ""
            for file in filenames
                extension = get_file_extension file
                unless extension in ["js", "coffee"]
                    throw new Error "Compress JS can only include .js or .coffee files"
                scripts += "<script src=\"/js/#{file}\"></script>"
            return scripts

    # Set up crons for cleanup and regen
    test_helper.cron = {}
    test_helper.cron.regenerated = 0
    new cron.CronJob(
        cronTime    : regen_cron
        onTick      : ->
            regen_stale_caches()
        start       : true
    )
    test_helper.cron.removed = 0
    new cron.CronJob(
        cronTime    : cleanup_cron
        onTick      : ->
            clear_old_caches()
        start       : true
    )

    if typeof callback is "function"
        # Send back file_groups so we can store it
        callback file_groups
