#!/usr/bin/env coffee

jade = require 'jade'
crypto = require 'crypto'
fs = require 'fs'
cp = require 'child_process'
mime = require 'mime'
uglify = require 'uglify-js'
sqwish = require 'sqwish'
utils = require('connect').utils

cwd = process.cwd()
paths = {
    cache   : {
        js  : "#{cwd}/js/cache"
        css : "#{cwd}/css/cache"
    }
    file_standard   : {
        js  : "#{cwd}/js"
        css : "#{cwd}/css"
    }
    file_abstract   : {
        js  : "#{cwd}/coffee"
        css : "#{cwd}/sass"
    }
    url     : {
        js  : "/js/cache"
        css : "/css/cache"
    }
}
file_groups = {}
processing = {}

# Either create or clear out cache dirs
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
    spool = ""
    coffee.stderr.on 'data', (data) ->
        return if failure
        error_txt = data.toString 'ascii'
        spool += new Buffer 'alert(\'COFFEE ERROR: ' + error_txt.split("\n")[0] + ' - FILEPATH: ' + filepath + '\');', 'ascii'
        failure = true
    coffee.stdout.on 'data', (data) ->
        spool += data
    coffee.stdout.on 'end', ->
        callback spool
    stream.pipe coffee.stdin

create_then_serve_file = (req, res, filetype, filenames) ->
    hash = create_hash filenames
    processing[hash] = true
    spool = []
    i = 0
    for index in [0...filenames.length]
        filename = filenames[index]
        spool.push index
        ((callback, index) ->
            done_parsing = (data) ->
                spool[index] = data
                i++
                callback() if i >= filenames.length
                
            extension = file_ext filename
            filepath = null
            if extension in ["js", "css"]
                filepath = "#{paths['file_standard'][filetype]}/#{filename}"
            else if extension in ["coffee", "scss"]
                filepath = "#{paths['file_abstract'][filetype]}/#{filename}"
                
            # Deal with COFFEE and JS files
            if filetype is "js"
                stream = fs.createReadStream filepath
                stream.pause()
                if extension is "js"
                    js_spool = ""
                    stream.on 'data', (data) ->
                        js_spool += data.toString 'ascii'
                    stream.on 'end', ->
                        done_parsing js_spool
                else if extension is "coffee"
                    coffee_to_js stream, (data) ->
                        done_parsing data.toString 'ascii'
                stream.resume()
                
            # Deal with SCSS and CSS files
            else if filetype is "css"
                if extension is "css"
                    fs.readFile filepath, 'ascii', (err, data) ->
                        done_parsing data
                else if extension is "scss"
                    sass = cp.spawn "sass", [filepath]
                    sass.stderr.on 'data', (data) ->
                        throw new Error "SASS: #{data.toString('ascii')}"
                    sass.stdout.on 'data', (data) ->
                        sass.kill 'SIGTERM'
                        # Sass puts in newlines, so let's remove those
                        data = data.toString 'ascii'
                        data = data.replace /\r\n|\r+|\n+/, ''
                        done_parsing data
        )(->
            filepath = "#{paths['cache'][filetype]}/#{hash}.#{filetype}"
            # Ensure that we write the data in the order it was listed
            data = ""
            for chunk in spool
                data += chunk
            if filetype is "js"
                data = mangle_js data
            if filetype is "css"
                data = sqwish.minify data
            fs.writeFile filepath, data, 'ascii', (err) ->
                processing[hash] = false
                serve_file req, res, filepath, true
        , index)
        
file_ext = (filename) ->
    a = filename.split "."
    return a[a.length - 1]
        
send_response = (req, res, filetype) ->
    filenames = file_groups[req.params.hash]
    if not filenames
        throw new Error "Problem, hash isn't in memory. This shouldn't happen."
        return
    filepath = "#{paths['cache'][filetype]}/#{req.params.hash}.#{filetype}"
    fs.stat filepath, (err, cache_stat) ->
        if not err
            # Check all of the files to see if any are newer than the cached file
            i = filenames.length
            stop_loop = false
            for filename in filenames
                ((callback) ->
                    return if stop_loop
                    extension = file_ext filename
                    path = null
                    if extension in ["js", "css"]
                        path = "#{paths['file_standard'][filetype]}/#{filename}"
                    else if extension in ["coffee", "scss"]
                        path = "#{paths['file_abstract'][filetype]}/#{filename}"
                    fs.stat path, (err, stat) ->
                        throw Error err if err
                        i--
                        if +stat.mtime > +cache_stat.mtime
                            stop_loop = true
                            callback true
                            return
                        callback false if i is 0
                ) (cache_is_stale) ->
                    if cache_is_stale
                        create_then_serve_file req, res, filetype, filenames
                    else if !cache_is_stale
                        serve_file req, res, filepath
                    
        else if err.code is "ENOENT"
            # This file has not been generated yet
            if processing[req.params.hash]
                # TODO: If the file is already being made we need to figure
                #       out how to wait for it to finish being created.
                return
            create_then_serve_file req, res, filetype, filenames
        else
            throw err

module.exports.views_init = (app) ->
    # Jade filter dependencies
    jade_get_filenames = (data) ->
        data = data.replace /\\n+$/, ''
        filenames = data.split /\\n+/
        return filenames
    
    jade_hash = (data) ->
        filenames = jade_get_filenames data
        hash = create_hash filenames
        # Force check on SASS dependencies
        for filename in filenames
            extension = file_ext filename
            if extension is "scss"
                # These dependencies are hard-coded.
                filenames.push "_vars.scss"
                filenames.push "_mixins.scss"
                break
        file_groups[hash] = filenames
        return hash

    jade.filters.compress_css = (data) ->
        hash = jade_hash data
        return "<link rel=\"stylesheet\" href=\"#{paths['url']['css']}/#{hash}.css\">"

    send_with_js_headers = (res, data) ->
        res.setHeader 'Content-Type', "text/javascript;charset=UTF-8"
        res.setHeader 'Date', new Date().toUTCString()
        res.setHeader 'Cache-Control', 'public, max-age=0'
        res.setHeader 'Last-Modified', new Date().toUTCString()
        res.send data

    app.get "#{paths['url']['css']}/:hash.css", (req, res) ->
        send_response req, res, "css"

    app.configure "development", ->
        # Don't compress CoffeeScript in development, just do coffee and sass
        app.get "/js/*.coffee", (req, res) ->
            filepath = "#{paths['file_abstract']['js']}/#{req.params[0]}.coffee"
            stream = fs.createReadStream filepath
            stream.pause()
            coffee_to_js stream, (data) ->
                # Instant expiry headers
                send_with_js_headers res, data
            , filepath
            stream.resume()

        app.get "/js/*.js", (req, res) ->
            filepath = "#{paths['file_standard']['js']}/#{req.params[0]}.js"
            stream = fs.createReadStream filepath
            stream.pause()
            js_spool = ""
            stream.on 'data', (data) ->
                js_spool += data.toString 'ascii'
            stream.on 'end', ->
                send_with_js_headers res, js_spool
            stream.resume()


        jade.filters.compress_js = (data) ->
            filenames = jade_get_filenames data
            scripts = ""
            for file in filenames
                scripts += "<script src=\"/js/#{file}\"></script>"
            return scripts

    app.configure "production", ->
        app.get "#{paths['url']['js']}/:hash.js", (req, res) ->
            send_response req, res, "js"

        jade.filters.compress_js = (data) ->
            hash = jade_hash data
            return "<script src=\"#{paths['url']['js']}/#{hash}.js\"></script>"



