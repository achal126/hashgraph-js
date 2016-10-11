EventEmitter = require('events')
# IPFS = require('ipfs')
co = require('co')
path = require('path')
os = require('os')
# mh = require('multihashes')

# TODO: use javascript ipfs implementation instead of spawning `ipfs`. But jsipfs does not support IPNS.
spawn = require('child_process').spawn

defaultOptions = {
  path: path.join(os.homedir(), '.hashgraph')
}

Array.prototype.rand = -> this[Math.floor(Math.random() * (this.length))]

hashgraph = (_options) ->
  options = Object.assign({}, defaultOptions, _options)
  path = options.path
  knownPeerIDs = []
  hashgraph = new EventEmitter()
  ipfs = null
  myPeerID = null
  head = null
  running = false
  payloadsForNextSync = []
  
  ########## Private
  publishEvent = (ownParentHash, otherParentHash, myPeerID, unixTimeMilli, payload) ->
    object = {}
    object.Data = JSON.stringify(c: myPeerID, t: unixTimeMilli, d: payload)
    object.Links = []
    object.Links.push({Name: '0', Hash: ownParentHash}) if ownParentHash
    object.Links.push({Name: '1', Hash: otherParentHash}) if otherParentHash
    ipfs.putObject(JSON.stringify(object))
    
  setHead = (eventHash) ->
    new Promise (resolve, reject) ->
      ipfs.publish(eventHash)
        .then ->
          head = eventHash
          resolve()
        .catch reject
  
  getHead = (peerID = myPeerID) ->
    ipfs.resolve(peerID)
  
  mainLoop = ->  
    c = knownPeerIDs.rand()
    newEvents = yield sync(c, payloadsForNextSync)
    divideRounds(newEvents)
    newC = decideFame()
    findOrder(newC)
    setTimeout(mainLoop, 1000) if running
  
  
  sync = co.wrap (c, payload) ->
    remoteHead = yield getHead(c)
    
    newEvents = bfs remoteHead, (u) -> (p for p in parents(u) if p not in height)
    
    #  new_evs = tuple(reversed(bfs((remote_head,),
    #             lambda u: (p for p in parents(u) if p not in self.height))))
     # 
    #     for u in new_evs:
    #         assert is_valid_event(u)
     # 
    #         pin_event(u)
     # 
    #         self.tbd.add(u)
    #         p = parents(u)
    #         if p == ():
    #             self.height[u] = 0
    #         else:
    #             self.height[u] = max(self.height[x] for x in p) + 1
     # 
    #     h = pub_event(Event((get_head(self.id), remote_head),
    #                         self.id, time(), payload))
    #     set_head(h)
     # 
    #     return new + (h,)  
  
  ########### Public
  hashgraph.info = ->
    return {
      peerID: myPeerID,
      head: head
    }
  
  hashgraph.init = co.wrap ->
    return Promise.resolve(hashgraph) if myPeerID      
    
    ipfs = require('./go-ipfs-adapter')(path)
    info = yield ipfs.getPeerInfo()
    if info
      console.log("Using Hashgraph Repo found in #{path}")
      myPeerID = info.ID
      head = yield getHead(myPeerID)  
      hashgraph.emit('ready')
      Promise.resolve(hashgraph)

    else
      console.log("Initializing a new Hashgraph Repo in #{path}")
      yield ipfs.init()
      info = yield ipfs.getPeerInfo()
      myPeerID = info.ID
      hash = yield publishEvent(null, null, myPeerID, new Date().getTime() / 1000, null)
      yield setHead(hash)
      hashgraph.emit('ready')
      Promise.resolve(hashgraph)
  
  hashgraph.start = ->
    running = true
    mainLoop()
    
  hashgraph.stop = ->
    running = false
          
  hashgraph.sendTransaction = (payload) -> 
    sendTransaction(payload)
  
  hashgraph.join = (peerID) ->
    knownPeerIDs.push(peerID)
      
  
  return hashgraph


module.exports = hashgraph
