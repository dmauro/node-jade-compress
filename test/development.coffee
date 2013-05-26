fs = require 'fs'
should = require 'should'
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
app.listen port, ip

cleanup_dirs = ["#{root_dir}/foo", "#{root_dir}/bar"]

cleanup = (done) ->
    # Delete all files in cache dir, then then the dir itself
    max = cleanup_dirs.length
    for dir in cleanup_dirs
        wipeout_dir = (dir, callback) ->
            remove_dir = ->
                fs.rmdir dir, (err) ->
                    throw err if err
                    callback()

            fs.readdir dir, (err, files) ->
                if err
                    return callback() if err.code is "ENOENT"
                    throw err
                file_count = files.length
                if file_count > 0
                    for file in files
                        filepath = "#{dir}/#{file}"
                        fs.stat filepath, (err, stats) ->
                            done_removing = (err) ->
                                throw err if err
                                file_count -= 1
                                if file_count is 0
                                    remove_dir()
                            if stats.isFile()
                                fs.unlink filepath, done_removing
                            else
                                wipeout_dir filepath, done_removing
                else
                    remove_dir()

        wipeout_dir dir, ->
            max -= 1
            if max is 0
                done()

before (done) ->
    cleanup ->
        compress.init(
            app             : app
            root_dir        : root_dir
            js_dir          : "foo"
            css_dir         : "bar"
            sass_load_paths : ["#{root_dir}/sass"]
        )
        done()

after (done) ->
    cleanup done

browser = null
beforeEach ->
    browser = new Zombie()

describe "Unfamiliar CSS and JS dir names", ->
    it "should have created the js dir", (done) ->
        fs.stat "#{root_dir}/foo", (err, dir_stat) ->
            should.not.exist err
            done()
    it "should have created the css dir", (done) ->
        fs.stat "#{root_dir}/bar", (err, dir_stat) ->
            should.not.exist err
            done()
    it "should have created the js/cache dir", (done) ->
        fs.stat "#{root_dir}/foo/cache", (err, dir_stat) ->
            should.not.exist err
            done()
    it "should have created the css/cache dir", (done) ->
        fs.stat "#{root_dir}/bar/cache", (err, dir_stat) ->
            should.not.exist err
            done()

describe "Filters", ->
    it "should not cut off an 'n' from the beginning of a file name", ->
        compiler = jade.compile("""
            :compress_js
                new_test.coffee
                nnn_test.coffee
                not_test.coffee
        """)
        html = compiler()
        scripts = html.split("</script>")
        source_array = []
        for script_tag in scripts
            regex = /"([^"]*)"/
            matches = regex.exec script_tag
            continue unless matches?
            source_array.push matches[1]
        source_array[0].should.equal "/js/new_test.coffee"
        source_array[1].should.equal "/js/nnn_test.coffee"
        source_array[2].should.equal "/js/not_test.coffee"
    it "shouldn't have a problem with extraneous line breaks", ->
        compiler = jade.compile("""
            :compress_js
                new_test.coffee
                nnn_test.coffee

                not_test.coffee

        """)
        html = compiler()
        scripts = html.split("</script>")
        source_array = []
        for script_tag in scripts
            regex = /"([^"]*)"/
            matches = regex.exec script_tag
            continue unless matches?
            source_array.push matches[1]
        source_array[0].should.equal "/js/new_test.coffee"
        source_array[1].should.equal "/js/nnn_test.coffee"
        source_array[2].should.equal "/js/not_test.coffee"

describe "Coffee", ->
    it "doesn't mangle coffeescript, only converts it", (done) ->
        compiler = jade.compile("""
            :compress_js
                another.coffee
                valid.coffee
        """)
        html = compiler()
        script_count = html.split("<script").length
        script_count.should.equal 3
        regex = /"([^"]*)"/
        matches = regex.exec html
        should.exist matches
        throw new Error "Regex fail" unless matches and matches.length
        cache_url = matches[1]
        browser.visit("#{url}#{cache_url}").then(->
            script = browser.text "body"
            script.length.should.not.equal 0
            script.indexOf("var filename").should.not.equal -1
            return
        ).then done, done

describe "Failures", ->
    it "alerts us to coffee compilation errors", (done) ->
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
            script.indexOf("SyntaxError").should.not.equal -1
            return
        ).then done, done

    it "alerts us to sass compilation errors", (done) ->
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
            style.indexOf("ERROR").should.not.equal -1
            return
        ).then done, done

describe "Caching", ->
    it "doesn't cache coffeescript files pulled individually", (done) ->
        before = """
            window.a_variable = "something"
            some_math = random.Math()
        """
        after = """
            window.a_variable = "zomething"
            some_math = random.Math()
        """
        fs. writeFileSync "#{root_dir}/coffee/temp.coffee", before
        browser.visit("#{url}/js/temp.coffee").then(->
            browser.resources.browser.response.headers['cache-control'].should.equal 'no-cache, no-store, public, max-age=0'
            browser.html().indexOf("something").should.not.equal -1
            fs. writeFileSync "#{root_dir}/coffee/temp.coffee", after
            browser.visit("#{url}/js/temp.coffee").then(->
                browser.resources.browser.response.headers['cache-control'].should.equal 'no-cache, no-store, public, max-age=0'
                browser.html().indexOf("zomething").should.not.equal -1
                done()
            ).fail done
            return
        ).fail done
    it "doesn't cache a file with a coffeescript error", (done) ->
        filename = "#{root_dir}/coffee/temp.coffee"
        before = """
            var window.a_variable = "something"
            some_math = random.Math()
        """
        after = """
            window.a_variable = "zomething"
            some_math = random.Math()
        """
        fs. writeFileSync filename, before
        browser.visit("#{url}/js/temp.coffee").then(->
            browser.resources.browser.response.headers['cache-control'].should.equal 'no-cache, no-store, public, max-age=0'
            browser.html().indexOf("Error").should.not.equal -1
            fs. writeFileSync "#{root_dir}/coffee/temp.coffee", after
            browser.visit("#{url}/js/temp.coffee").then(->
                browser.resources.browser.response.headers['cache-control'].should.equal 'no-cache, no-store, public, max-age=0'
                browser.html().indexOf("zomething").should.not.equal -1
                fs.unlinkSync filename
                done()
            ).fail done
            return
        ).fail done