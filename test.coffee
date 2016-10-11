hashgraph1 = require('hashgraph')(path: '~/.hashgraph1')
hashgraph1.init().catch console.error

hashgraph1.on 'ready', ->
  hashgraph1.start()
  peer1ID = hashgraph1.info().peerID
  
  hashgraph2 = require('hashgraph')(path: '~/.hashgraph2')
  hashgraph2.init().catch console.error

  hashgraph2.on 'ready', ->
    
    peer2ID = hashgraph2.info().peerID
    
    hashgraph2.join(peer1ID)
    hashgraph2.start()
