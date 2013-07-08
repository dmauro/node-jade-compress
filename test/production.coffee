fs = require 'fs'
cp = require 'child_process'
should = require 'should'
assert = require 'assert'
compress = require '../index'
express = require 'express'
jade = require 'jade'
Zombie = require 'zombie'

app = null
file_groups = null
cwd = process.cwd()
ip = "127.0.0.1"
port = 7005
url = "http://#{ip}:#{port}"
root_dir = "#{cwd}/test/server_root"

app = express.createServer()
app.set "views", "#{root_dir}/views"
app.set "view engine", "jade"
app.set "view options", {layout: false}
app.get "/js_async", (req, res) ->
    res.render "js_async"
app.get "/jquery", (req, res) ->
    res.render "jquery"
app.listen port, ip

cleanup_dirs = ["#{root_dir}/js/cache", "#{root_dir}/css/cache"]

cleanup = (done) ->
    # Delete all files in cache dir, then then the dir itself
    max = cleanup_dirs.length
    for dir in cleanup_dirs
        ((dir) ->
            finish_up = ->
                max -= 1
                if max is 0
                    done()

            remove_dir = ->
                fs.rmdir dir, (err) ->
                    throw err if err
                    finish_up()

            fs.readdir dir, (err, files) ->
                if err
                    return finish_up() if err.code is "ENOENT"
                    throw err
                file_count = files.length
                if file_count > 0
                    for file in files
                        ext = file.split "."
                        fs.unlink "#{dir}/#{file}", (err) ->
                            throw err if err
                            file_count -= 1
                            if file_count is 0
                                remove_dir()
                else
                    remove_dir()

        )(dir)

before (done) ->
    cleanup done

after (done) ->
    cleanup done

describe "Requirements", ->
    it "can spawn coffeescript process", (done) ->
        failed = false
        c = cp.spawn "coffee", ["--version"]
        c.stderr.on 'data', (data) ->
            failed = true
        c.stdout.on 'end', ->
            setTimeout ->
                return done new Error "CoffeeScript not available from command line" if failed
                done()
            , 100
    it "can spawn sass process", (done) ->
        failed = false
        c = cp.spawn "sass", ["--version"]
        c.stderr.on 'data', (data) ->
            failed = true
        c.stdout.on 'end', ->
            setTimeout ->
                return done new Error "Sass not available from command line" if failed
                done()
            , 100

describe "Setup", ->
    describe "directories", ->
        it "should have permission to create directories", (done) ->
            try
                compress.init({
                    app             : app
                    root_dir        : root_dir
                    cleanup_cron    : "0 0 0 0 1 *"
                    regen_cron      : "0 0 0 0 1 *"
                    sass_load_paths : ["#{root_dir}/sass"]
                }, (_file_groups) ->
                    file_groups = _file_groups
                    done()
                )
            catch err
                should.not.exist err
                done()

        it "should have created the js/cache dir", (done) ->
            fs.stat "#{root_dir}/js/cache", (err, dir_stat) ->
                should.not.exist err
                done()
        it "should have created the css/cache dir", (done) ->
            fs.stat "#{root_dir}/css/cache", (err, dir_stat) ->
                should.not.exist err
                done()

    describe "jade filters", ->
        it "should create the jade filters", ->
            should.exist jade.filters.compress_js
            should.exist jade.filters.compress_js_async
            should.exist jade.filters.compress_css
        describe "js filter", ->
            it "should return a script tag if valid", ->
                tag = jade.filters.compress_js "foo.coffee\nbar.js"
                tag.substr(0, 13).should.equal "<script src=\""
                tag.substr(-11, 11).should.equal "\"></script>"
            it "should return an empty string if invalid", ->
                empty = jade.filters.compress_js "foo.bar"
                empty.should.equal ""

        describe "js async filter", ->
            it "should return a script tag if valid", ->
                tag = jade.filters.compress_js_async "foo.coffee\nbar.js"
                tag.substr(0, 8).should.equal "<script>"
                tag.substr(-9, 9).should.equal "</script>"
            it "should return an empty string if invalid", ->
                empty = jade.filters.compress_js_async "foo.bar"
                empty.should.equal ""

        describe "css filter", ->
            it "should return a style tag if valid", ->
                tag = jade.filters.compress_css "foo.scss\nbar.css"
                tag.substr(0, 29).should.equal "<link rel=\"stylesheet\" href=\""
                tag.substr(-2, 2).should.equal "\">"
            it "should return an empty string if invalid", ->
                empty = jade.filters.compress_css "foo.bar"
                empty.should.equal ""

describe "Coffee compression", ->
    browser = null
    beforeEach ->
        browser = new Zombie()

    it "can convert coffee files into a single bunch of mangled js", (done) ->
        compiler = jade.compile("""
            :compress_js
                valid.coffee
                another.coffee
        """)
        html = compiler()
        regex = /"([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            script = browser.text "body"
            script.length.should.not.equal 0
            newline_count = script.split("\n").length
            assert.ok newline_count < 2
            return
        ).then done, done
    it "can convert coffee mixed with js files into a single bunch of mangled js", (done) ->
        compiler = jade.compile("""
            :compress_js
                valid.coffee
                valid.js
        """)
        html = compiler()
        regex = /"([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            script = browser.text "body"
            script.length.should.not.equal 0
            return
        ).then done, done
    it "will serve up an empty file if coffee conversion fails", (done) ->
        compiler = jade.compile("""
            :compress_js
                invalid.coffee
        """)
        html = compiler()
        regex = /"([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            script = browser.text "body"
            script.length.should.equal 0
            return
        ).then done, done
    it "will serve 404 if any any Coffee files don't exist", (done) ->
        compiler = jade.compile("""
            :compress_js
                foo.coffee
        """)
        html = compiler()
        regex = /"([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            done new Error "Should have 404'd"
        ).fail((err) ->
            browser.statusCode.should.equal 404
            done()
        )
    it "will serve 404 if any any JS files don't exist", (done) ->
        compiler = jade.compile("""
            :compress_js
                foo.js
        """)
        html = compiler()
        regex = /"([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            done new Error "Should have 404'd"
        ).fail((err) ->
            browser.statusCode.should.equal 404
            done()
        )
    it "will serve 404 if the hash doesn't exist", (done) ->
        compiler = jade.compile("""
            :compress_js
                foo.js
        """)
        html = compiler()
        hash_regex = /(?:cache\/)([^.]*)/
        matches = hash_regex.exec html
        throw new Error "Hash Regex fail" unless matches.length
        hash = matches[1]
        hash = hash.split("-")[0]
        # DELETE THE HASH AS THE CRON WOULD DO
        delete file_groups[hash]
        url_regex = /"([^"]*)"/
        matches = url_regex.exec html
        throw new Error "URL Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            done new Error "Should have 404'd"
        ).fail((err) ->
            browser.statusCode.should.equal 404
            done()
        )
    it "will properly load javascript asynchronously with compress_js_async filter", (done) ->
        browser.visit("#{url}/js_async").then(->
            regex = /<script async="true" src="([^"]*)/gm
            matches = regex.exec browser.html()
            throw new Error "URL Regex fail" unless matches and matches.length
            js_url = matches[1]
            browser.visit("#{url}#{js_url}").then(->
                script = browser.text "body"
                script.length.should.not.equal 0
                return
            ).then done, done
        ).fail((err) ->
            done err
        )
    it "will serve 404 when requesting a single coffee file that doesn't exist", (done) ->
        browser.visit("#{url}/js/foobar.coffee").then(->
            throw new Error "Should have 404'd"
        ).fail((err) ->
            browser.statusCode.should.equal 404
            done()
        )
    it "will serve 404 when requesting a single js file that doesn't exist", (done) ->
        browser.visit("#{url}/js/foobar.js").then(->
            throw new Error "Should have 404'd"
        ).fail((err) ->
            browser.statusCode.should.equal 404
            done()
        )

describe "Sass compression", ->
    browser = new Zombie()

    it "can convert sass files into a single css file", (done) ->
        compiler = jade.compile("""
            :compress_css
                valid.scss
                another.scss
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            style = browser.text "body"
            style.length.should.not.equal 0
            return
        ).then done, done
    it "can convert sass files mixed with css files into a single css file", (done) ->
        compiler = jade.compile("""
            :compress_css
                valid.scss
                valid.css
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            style = browser.text "body"
            style.length.should.not.equal 0
            return
        ).then done, done
    it "bakes any includes into all sass files", (done) ->
        compiler = jade.compile("""
            :compress_css
                has_import.scss
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            style = browser.text "body"
            style.length.should.not.equal 0
            return
        ).then done, done
    it "will serve up an empty file if sass conversion fails", (done) ->
        compiler = jade.compile("""
            :compress_css
                invalid.scss
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            style = browser.text "body"
            style.length.should.equal 0
            return
        ).then done, done
    it "will serve up an empty file if any imported files don't exist", (done) ->
        compiler = jade.compile("""
            :compress_css
                invalid_imports.scss
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            style = browser.text "body"
            style.length.should.equal 0
            return
        ).then done, done
    it "will serve 404 if any sass files don't exist", (done) ->
        compiler = jade.compile("""
            :compress_css
                foo.scss
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            done new Error "Should have 404'd"
        ).fail((err) ->
            browser.statusCode.should.equal 404
            done()
        )
    it "will serve 404 if any css files don't exist", (done) ->
        compiler = jade.compile("""
            :compress_css
                foo.css
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            done new Error "Should have 404'd"
        ).fail((err) ->
            browser.statusCode.should.equal 404
            done()
        )
    it "will serve 404 if the hash doesn't exist", (done) ->
        compiler = jade.compile("""
            :compress_css
                bar.css
        """)
        html = compiler()
        hash_regex = /(?:cache\/)([^.]*)/
        matches = hash_regex.exec html
        throw new Error "Hash Regex fail" unless matches.length
        hash = matches[1]
        hash = hash.split("-")[0]
        # DELETE THE HASH AS THE CRON WOULD DO
        delete file_groups[hash]
        url_regex = /href="([^"]*)"/
        matches = url_regex.exec html
        throw new Error "URL Regex fail" unless matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            done new Error "Should have 404'd"
        ).fail((err) ->
            browser.statusCode.should.equal 404
            browser.statusCode.should.equal 404
            done()
        )

describe "Requests", ->
    browser = null

    beforeEach ->
        browser = new Zombie()

    it "can convert coffee to js when a coffee file is requested from the js directory", (done) ->
        browser.visit("#{url}/js/valid.coffee").then(->
            script = browser.text "body"
            script.length.should.not.equal 0
            return
        ).then done, done
    it "will serve up any files from the js directory", (done) ->
        browser.visit("#{url}/js/valid.js").then(->
            script = browser.text "body"
            script.length.should.not.equal 0
            return
        ).then done, done
    it "can convert sass to css when a sass file is requested as css", (done) ->
        browser.visit("#{url}/css/valid.scss").then(->
            style = browser.text "body"
            style.length.should.not.equal 0
            return
        ).then done, done
    it "can properly mangle and serve jQuery", (done) ->
        browser.visit("#{url}/jquery").then(->
            regex = /<script src="([^"]*)/gm
            matches = regex.exec browser.html()
            throw new Error "URL Regex fail" unless matches and matches.length
            should.exist browser.window.$
            return
        ).then done, done
    it "can serve up a cached file to simultaneous requests even if it doesn't exist yet", (done) ->
        second_browser = new Zombie()
        # We have to have no yet generated this in our tests
        compiler = jade.compile("""
            :compress_css
                valid.scss
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        count = 2
        finalize = (err) ->
            done err if err
            count -= 1
            if count is 0
                done()
        # Both of these browsers head for the url at the same time
        browser.visit("#{url}#{cache_url}").then(->
            style = browser.text "body"
            style.length.should.not.equal 0
            return
        ).then finalize, finalize
        second_browser.visit("#{url}#{cache_url}").then(->
            style = browser.text "body"
            style.length.should.not.equal 0
            return
        ).then finalize, finalize
    it "will serve up a cached file that has already been generated reasonably fast", (done) ->
        compiler = jade.compile("""
            :compress_css
                valid.scss
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        before = new Date().getTime()
        browser.visit("#{url}#{cache_url}").then(->
            after = new Date().getTime()
            assert.ok after - before < 100
            return
        ).then done, done
    it "will recognize if a cached file is stale and regenerate it", (done) ->
        setTimeout(->
            fs.utimes "#{root_dir}/sass/valid.scss", new Date(), new Date(), ->
                compiler = jade.compile("""
                    :compress_css
                        valid.scss
                """)
                html = compiler()
                regex = /href="([^"]*)"/
                matches = regex.exec html
                should.exist matches
                return done() unless matches.length
                cache_url = matches[1]
                count = compress.test_helper.files_generated
                setTimeout(->
                    browser.visit("#{url}#{cache_url}").then(->
                        compress.test_helper.files_generated.should.equal count + 1
                        return
                    ).then done, done
                , 1000)
        , 1000)
    it "will recognize if a cached css file is stale if imported file gets touched", (done) ->
        setTimeout(->
            fs.utimes "#{root_dir}/sass/mixins.scss", new Date(), new Date(), ->
                compiler = jade.compile("""
                    :compress_css
                        has_import.scss
                """)
                html = compiler()
                regex = /href="([^"]*)"/
                matches = regex.exec html
                should.exist matches
                return done() unless matches.length
                cache_url = matches[1]
                count = compress.test_helper.files_generated
                setTimeout(->
                    browser.visit("#{url}#{cache_url}").then(->
                        compress.test_helper.files_generated.should.equal count + 1
                        return
                    ).then done, done
                , 1000)
        , 1000)
    it "filename will change when we update a constituent file, and not otherwise", (done) ->
        compiler = jade.compile("""
            :compress_css
                has_import.scss
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        should.exist matches
        cache_url = matches[1]
        setTimeout( ->
            fs.utimes "#{root_dir}/sass/mixins.scss", new Date(), new Date(), ->
                browser.visit("#{url}#{cache_url}").then(->
                    compiler = jade.compile("""
                        :compress_css
                            has_import.scss
                    """)
                    html = compiler()
                    regex = /href="([^"]*)"/
                    matches = regex.exec html
                    should.exist matches
                    new_cache_url = matches[1]
                    new_cache_url.should.not.equal cache_url
                    browser.visit("#{url}#{cache_url}").then(->
                        compiler = jade.compile("""
                            :compress_css
                                has_import.scss
                        """)
                        html = compiler()
                        regex = /href="([^"]*)"/
                        matches = regex.exec html
                        should.exist matches
                        newer_cache_url = matches[1]
                        newer_cache_url.should.equal new_cache_url
                        done()
                    ).fail done
                ).fail done
        , 2000)
    it "will 304 on a request that hasn't changed for a js cache file", (done) ->
        compiler = jade.compile("""
            :compress_js
                valid.coffee
                another.coffee
        """)
        html = compiler()
        regex = /"([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}", { headers: {'if-modified-since': new Date()}}).then(->
            browser.statusCode.should.equal 304
            return
        ).then done, done
    it "will 304 on a request that hasn't changed for a css cache file", (done) ->
        compiler = jade.compile("""
            :compress_css
                valid.scss
        """)
        html = compiler()
        regex = /href="([^"]*)"/
        matches = regex.exec html
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}", { headers: {'if-modified-since': new Date()}}).then(->
            browser.statusCode.should.equal 304
            return
        ).then done, done

describe "Cron", ->
    before (done) ->
        # Run these and then wait a bit to make sure there are no time collisions
        compress.test_helper.clear_cron()
        compress.test_helper.regen_cron()
        setTimeout done, 1000

    it "find cache files that are stale and regenerate them", (done) ->
        regenerated = compress.test_helper.cron.regenerated
        setTimeout(->
            fs.utimes "#{root_dir}/sass/another.scss", new Date(), new Date(), ->
                compress.test_helper.regen_cron()
                setTimeout(->
                    compress.test_helper.cron.regenerated.should.equal regenerated + 1
                    done()
                , 500) # Give the cron time to run because it has no callback
        , 1000)

    it "find cache files that are old and delete them", (done) ->
        removed = compress.test_helper.cron.removed
        compress.test_helper.clear_cron()
        setTimeout(->
            assert.ok compress.test_helper.cron.removed > removed
            done()
        , 500) # Give the cron time to run because it has no callback

    it "won't break if there an invalid cache", (done) ->
        compiler = jade.compile("""
            :compress_css
                dne.scss
        """)
        html = compiler()
        compress.test_helper.regen_cron()
        setTimeout(->
            # Just watching to see if server throws out an error
            done()
        , 500)

# TODO: Test that we can restart the server by saving file_groups to db
