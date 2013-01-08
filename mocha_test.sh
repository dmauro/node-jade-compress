#!/bin/bash
cd "$( cd "$( dirname "$0" )" && pwd )"
NODE_ENV=test mocha test/production.coffee
