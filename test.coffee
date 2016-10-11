hashgraph = require('hashgraph')()

hashgraph.init().catch console.error

hashgraph.on 'ready', ->
  hashgraph.start()
  console.log hashgraph.info()
