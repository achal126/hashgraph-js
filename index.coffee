EventEmitter = require('events')
# IPFS = require('ipfs')
co = require('co')
ospath = require('path')
os = require('os')
# mh = require('multihashes')

# TODO: use javascript ipfs implementation instead of spawning `ipfs`. But jsipfs does not support IPNS.
spawn = require('child_process').spawn

defaultOptions = {
  path: ospath.join(os.homedir(), '.hashgraph'),
  logPrefix: ''
}

Array.prototype.rand = -> if this.length == 0 then null else this[Math.floor(Math.random() * (this.length))]


toposort = (nodes, parents) ->
  seen = {}
  visit = (u) ->
    if seen[u]?
      if seen[u] == 0
        throw 'not a DAG'
    else if u in nodes
      seen[u] = 0
      for v in parents(u)
          yield from visit(v)
      seen[u] = 1
      yield u
  for u in nodes
      yield from visit(u)

# Returns an array of all hashes visited during BFS lookup
# successor promise has to resolve into empty array to signal end
bfs = co.wrap (s, succ) ->
  seen = [s]
  q = [s]
  visited = []
  while q
    u = q.unshift()
    visited.push(u)
    for v in yield succ(u)
      if not v in seen
        seen.add(v)
        q.append(v)
  return visited

dfs = (s, succ) ->
  seen = []
  q = [s]
  while q
    u = q.pop()
    yield u
    seen.add(u)
    for v in succ(u)
      if v not in seen
        q.append(v)


hashgraph = (_options) ->
  # private node configuration vars
  options = Object.assign({}, defaultOptions, _options)
  path = options.path
  knownPeerIDs = []
  hashgraph = new EventEmitter()
  ipfs = null
  myPeerID = null
  head = null
  running = false
  payloadsForNextSync = []
  
  # Private Algorithm Vars
  # These have to be rebuild every time the client starts. might take a long time if it's big.
  height = {}
  famous = {}
  canSee = {}
  round = {}
  
  ########## Private
  log = (args...) ->
    console.log(options.logPrefix, args...)
  
  error = (args...) ->
    console.error(options.logPrefix, args...)
  
  
  publishEvent = (ownParentHash, otherParentHash, myPeerID, unixTimeMilli, payload) ->
    object = {}
    object.Data = JSON.stringify(c: myPeerID, t: unixTimeMilli, d: payload)
    object.Links = []
    object.Links.push({Name: '0', Hash: ownParentHash}) if ownParentHash
    object.Links.push({Name: '1', Hash: otherParentHash}) if otherParentHash
    ipfs.putObject(JSON.stringify(object))
    
  parents = co.wrap (u) ->
    json = yield ipfs.getObject(u)
    obj = JSON.parse(json)
    return (link['Hash'] for link in obj['Links'])
    
  setHead = (eventHash) ->
    new Promise (resolve, reject) ->
      ipfs.publish(eventHash)
        .then ->
          head = eventHash
          resolve()
        .catch reject
  
  getHead = (peerID = myPeerID) ->
    ipfs.resolve(peerID)
  
  mainLoop = co.wrap ->
    c = knownPeerIDs.rand()
    if (c)
      log('Start Sync with', c)
      newEvents = yield sync(c, payloadsForNextSync).catch error
      divideRounds(newEvents)
      newC = decideFame()
      findOrder(newC)
      # TODO: emit consensus event
    else
      log('no nodes to sync')
    setTimeout(mainLoop, 1000) if running
  
  divideRounds = ->
    true # TODO
  
  
  decideFame = ->
    [] # TODO
    
  findOrder = (newC) ->
    true # TODO
  
  sync = co.wrap (remoteNodeID, payload) ->
    remoteHead = yield getHead(remoteNodeID)
    newEvents = yield bfs remoteHead, co.wrap (u) -> (p for p in yield(parents(u)) if p not in height)
    
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
      log("Using Hashgraph Repo found in #{path}")
      myPeerID = info.ID
      head = yield getHead(myPeerID)  
      hashgraph.emit('ready')
      Promise.resolve(hashgraph)

    else
      log("Initializing a new Hashgraph Repo in #{path}")
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
