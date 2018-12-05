# hdeploy
HDeploy client ruby gem

# Testing/development
This is a distributed application with many elements to it so it requires a little bit of scaffolding.

The different elements to dev/test are:
- Backend database (MySQL, Cassandra, and SQLite for dev purposes)
- HTTP API
- Repository (can be served by the API for development purposes)
- Hdeploy node daemon (client)
- CLI tool

To make it easier, this could be done with
- SQLite that auto-fills
- Default configs that are sane (directory: hdeploy-dev/sample-app/ etc)
- A default sample app
- A default local listen port/etc
-


First TODO: add database backend abstraction
And add SQLite support
(later on, MySQL too)
They should both return some data structures that are identical
Have all the same basic queries