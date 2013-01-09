#!/bin/bash
cd "$( cd "$( dirname "$0" )" && pwd )"
echo "Production Environment Tests"
NODE_ENV=production mocha test/production.coffee
echo "Dev Environment Tests"
NODE_ENV=development mocha test/development.coffee
