#!/usr/bin/env coffee
crypto = require 'crypto'
fs = require 'fs'
cp = require 'child_process'
mime = require 'mime'
uglify = require 'uglify-js'
sqwish = require 'sqwish'
cron = require 'cron'
utils = require('connect').utils
coffeescript = require 'coffee-script'
sass = require 'node-sass'
use_sass_cli = true
paths = {}
test_helper = {
    files_generated : 0
}
sass_load_paths = []

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
        else if process.env.NODE_ENV is "development"
            spool += new Buffer 'alert(\'COFFEE ERROR: ' + error_txt.split("\n")[0] + ' - FILEPATH: ' + filepath + '\');', 'ascii'
        failure = true
    coffee.stdout.on 'data', (data) ->
        spool += data
    coffee.stdout.on 'end', ->
        callback spool unless is_enoent
    stream.pipe coffee.stdin

add_sass_imports_to_filegroup = (sass_data, filepath, callback) ->
    return callback []
    # TODO: All filenames need full paths for this to work

    current_dir = filepath.split("/").slice(0, -1).join("/") + "/"
    import_filenames = []
    import_regex = /@import[^;]*;/gm
    line_regex = /[^"']+(?=(["'],( )?["'])|["'];$)/g
    import_lines = sass_data.match(import_regex) or []
    import_lines.reverse()
    imports_count = 0
    decr = ->
        imports_count -= 1
        if imports_count is 0
            return callback import_filenames
    for line in import_lines
        imports = line.match(line_regex) or []
        imports.reverse()
        for import_filename in imports
            imports_count += 1
            (->
                extension = get_file_extension import_filename
                if extension is "css"
                    return decr()
                unless extension.length
                    import_filename += ".scss"
                look_for = ["#{current_dir}#{import_filename}"]
                for dir in sass_load_paths
                    look_for.push "#{dir}#{import_filename}"
                
                search_loop = (count) ->
                    count = count or 0
                    if count >= look_for.length
                        # None of the filepaths found the import
                        decr()
                    filepath = look_for[count]
                    fs.stat filepath, (err, stat) ->
                        count += 1
                        if stat
                            # Found the file
                            import_filenames.unshift filepath
                            decr()
                        else
                            search_loop count
                search_loop()
            )()

sass_to_css = (filepath, callback, imports_found_callback) ->
    if use_sass_cli
        # We probably won't need this
        spool = ""
        is_enoent = false
        sass = cp.spawn "sass", [filepath]
        if imports_found_callback?
            scss_spool = ""
            import_is_enoent = false
            stream = fs.createReadStream filepath
            stream.pause()
            stream.on 'error', (data) ->
                import_is_enoent = true
            stream.on 'data', (data) ->
                scss_spool += data.toString 'ascii'
            stream.on 'end', ->
                return if import_is_enoent
                add_sass_imports_to_filegroup scss_spool, filepath, imports_found_callback
            stream.resume()
        sass.stderr.on 'data', (data) ->
            error_txt = data.toString 'ascii'
            if error_txt.indexOf("ENOENT") > -1
                is_enoent = true
                return callback null
            else if process.env.NODE_ENV is "development"
                # CSS trick to get the error on screen
                spool += "body:before{content:\"SASS ERROR: #{error_txt.replace(/"/g, "\\\"")}\";font-size:16px;font-family:monospace;color:#900;}"
                spool += error_txt
        sass.stdout.on 'data', (data) ->
            # Sass puts in newlines, so let's remove those
            data = data.toString 'ascii'
            data = data.replace /\r\n|\r+|\n+/, ''
            spool += data
        sass.stdout.on 'end', ->
            sass.kill 'SIGTERM'
            callback spool unless is_enoent
    else
        # Use node-sass plugin
        scss_spool = ""
        is_enoent = false
        stream = fs.createReadStream filepath
        stream.pause()
        stream.on 'error', (data) ->
            if data.toString('ascii').indexOf('ENOENT') > -1
                is_enoent = true
                return callback null
        stream.on 'data', (data) ->
            scss_spool += data.toString 'ascii'
        stream.on 'end', ->
            return if is_enoent
            # Check if we have any imports, so that they can be added to File groups
            if imports_found_callback?
                add_sass_imports_to_filegroup scss_spool, filepath, imports_found_callback

            # Render to CSS
            sass.render scss_spool, (err, css) ->
                if err
                    if process.env.NODE_ENV is "development"
                        return callback "body:before{content:\"#{err.replace(/"/g, "\\\"")}\";font-size:16px;font-family:monospace;color:#900;}"
                    else
                        return callback ""
                else
                    return callback css
        stream.resume()

        
get_file_extension = (filename) ->
    a = filename.split "/"
    a = a[a.length - 1]
    a = a.split "."
    return "" unless a.length > 1
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
                # If this hash is invalid due to 404, we should clear it
                delete file_groups[hash] if file_groups[hash]?
                return res.send 404 if res

            done_parsing = (data) ->
                # Ensure we write the data in the order the files were listed
                spool[index] = data
                i++
                callback() if i >= max
                
            extension = get_file_extension filename
                
            # Deal with COFFEE and JS files
            if filetype is "js"
                stream = fs.createReadStream filename
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
                    fs.readFile filename, 'ascii', (err, data) ->
                        if err and err.code is "ENOENT"
                            return file_not_found()
                        throw err if err
                        done_parsing data
                else if extension is "scss"
                    sass_to_css filename, (data) ->
                        unless data?
                            return file_not_found()
                        done_parsing data
                    , (import_filenames) ->
                        # Sass @import is found callback
                        for import_filename in import_filenames
                            if import_filename not in file_groups[hash]
                                file_groups[hash].push import_filename
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

create_then_serve_file = (req, res, hash, filetype, filenames) ->
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
        fs.stat filename, (err, stat) ->
            i--
            unless err
                if +stat.mtime > +cache_mtime
                    callback true unless is_done
                    is_done = true
            callback false if i is 0 and !is_done
        
send_response = (req, res, filetype) ->
    hash = req.params.hash
    filenames = file_groups[hash]
    return res.send 404 unless filenames
    filepath = "#{paths['cache'][filetype]}/#{req.params.hash}.#{filetype}"
    fs.stat filepath, (err, cache_stat) ->
        if not err
            cache_is_stale cache_stat.mtime, filenames, (is_stale) ->
                if is_stale
                    create_then_serve_file req, res, hash, filetype, filenames
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
                create_then_serve_file req, res, hash, filetype, filenames
        else
            throw err

test_helper.regen_cron = regen_stale_caches = ->
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
    jade = settings.jade or require 'jade'
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
    regen_cron = settings.regen_cron or '*/10 * * * * *'
    cleanup_cron = settings.cleanup_cron or '00 00 00 * * 0'
    # Cron Syntax
    # Second(0-59) Minute(0-59) Hour(0-23) DayMonth(1-31) Month(1-12) DayWeek(0-6/Sunday-Saturday)
    sass_load_paths = settings.sass_load_paths or []

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
        continue if name in ['url']
        for type, dir of group
            ((dir) ->
                fs.stat dir, (err, cache_stat) ->
                    if err and err.code is "ENOENT"
                        fs.mkdir dir, 0o0755, (err) ->
                            throw err if err
            )(dir)

    # Jade filter dependencies
    jade_get_filepaths = (data) ->
        filenames = jade_get_filenames data
        for i in [0...filenames.length]
            extension = get_file_extension filenames[i]
            if extension is "js"
                dir = paths['file_standard']['js']
            else if extension is "coffee"
                dir = paths['file_abstract']['js']
            else if extension is "css"
                dir = paths['file_standard']['css']
            else if extension is "scss"
                dir = paths['file_abstract']['css']
            else
                continue
            filenames[i] = "#{dir}/#{filenames[i]}"
        return filenames

    jade_get_filenames = (data) ->
        data = data.replace /\\n+$/, ''
        filenames = data.split /\\n+/
        return filenames
    
    jade_hash = (data, filetype) ->
        filenames = jade_get_filepaths data
        # Force check on SASS dependencies
        for filename in filenames
            extension = get_file_extension filename
            if filetype is "js" and extension not in ["js", "coffee"]
                # Compress JS can only include .js or .coffee files
                return null
            else if filetype is "css" and extension not in ["css", "scss"]
                # Compress CSS can only include .css or .scss files
                return null
        hash = create_hash filenames
        file_groups[hash] = filenames unless file_groups[hash]?
        return hash

    jade.filters.compress_css = (data) ->
        hash = jade_hash data, "css"
        return "" unless hash
        return "<link rel=\"stylesheet\" href=\"#{paths['url']['css']}/#{hash}.css\">"

    jade.filters.compress_js = (data) ->
        hash = jade_hash data, "js"
        return "" unless hash
        return "<script src=\"#{paths['url']['js']}/#{hash}.js\"></script>"

    jade.filters.compress_js_async = (data) ->
        hash = jade_hash data, "js"
        return "" unless hash
        return "<script>var d = document,s = d.createElement('script'),h = d.getElementsByTagName('head')[0];s.setAttribute('async', true);s.src = \"#{paths['url']['js']}/#{hash}.js\";h.appendChild(s);</script>"

    # These are mostly just to help looking at your files
    # you should not send your users to these:
    send_with_instant_expiry = (res, data) ->
        res.setHeader 'Date', new Date().toUTCString()
        res.setHeader 'Cache-Control', 'public, max-age=0'
        res.setHeader 'Last-Modified', new Date().toUTCString()
        res.send data

    send_with_instant_expiry_js_headers = (res, data) ->
        res.setHeader 'Content-Type', "text/javascript;charset=UTF-8"
        send_with_instant_expiry res, data

    send_with_instant_expiry_css_headers = (res, data) ->
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
        is_enoent = false
        stream.on 'error', (err) ->
            is_enoent = true
            res.send 404
        coffee_to_js stream, (data) ->
            return if is_enoent
            send_with_instant_expiry_js_headers res, data
        , filepath
        stream.resume()

    app.get "#{js_url}/*.js", (req, res) ->
        filepath = "#{paths['file_standard']['js']}/#{req.params[0]}.js"
        stream = fs.createReadStream filepath
        stream.pause()
        js_spool = ""
        is_enoent = false
        stream.on 'error', (data) ->
            is_enoent = true
            res.send 404
        stream.on 'data', (data) ->
            js_spool += data.toString 'ascii'
        stream.on 'end', ->
            return if is_enoent
            send_with_instant_expiry_js_headers res, js_spool
        stream.resume()
        send_response req, res, "js"

    app.get "#{css_url}/*.scss", (req, res) ->
        filepath = "#{paths['file_abstract']['css']}/#{req.params[0]}.scss"
        sass_to_css filepath, (data) ->
            send_with_instant_expiry_css_headers res, data

    if process.env.NODE_ENV is "development"
        # Don't compress CoffeeScript in development, only convert to JS
        jade.filters.compress_js = (data) ->
            filenames = jade_get_filenames data
            scripts = ""
            for file in filenames
                extension = get_file_extension file
                scripts += "<script src=\"#{js_url}/#{file}\"></script>"
            return scripts

        ### This won't work unless we control the order they are executed in
        jade.filters.compress_js_async = (data) ->
            filenames = jade_get_filepaths data
            script = "<script>var d=document,h=d.getElementsByTagName('head')[0];"
            for i in [0...filenames.length]
                filename = filenames[i]
                script += "var s_#{i}=d.createElement('script');s_#{i}.setAttribute('async',true);s_#{i}.src=\"#{js_url}/#{file}\";h.appendChild(s);"
            script += "</script>"
            return script
        ###

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
