EventEmitter = require('events')
co = require('co')
ospath = require('path')
os = require('os')
# mh = require('multihashes')

# TODO: use javascript ipfs implementation instead of spawning `ipfs` process when they've implemented IPNS in javascript
spawn = require('child_process').spawn

defaultOptions = {
  path: ospath.join(os.homedir(), '.hashgraph'),
  logPrefix: ''
}

Array.prototype.rand = -> if this.length == 0 then null else this[Math.floor(Math.random() * (this.length))]


toposort = (nodes, getParents) ->
  seen = {}
  visit = (u) ->
    if seen[u]?
      if seen[u] == 0
        throw 'not a DAG'
    else if u in nodes
      seen[u] = 0
      for v in getParents(u)
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

dfs = co.wrap (s, succ) ->
  seen = []
  q = [s]
  visited = []
  while q
    u = q.pop()
    visited.push(u)
    seen.add(u)
    for v in yield succ(u)
      if v not in seen
        q.append(v)
  return visited


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
  # These have to be rebuild every time the client starts. might take a long time if the hashgraph is large. maybe we can persist these between restart
  heightTable =    {} # Stores the height of events in the hashgraph
  famousTable =    {} # Stores weither or not an event is famous
  canSeeTable =    {} # Stores a list of events that can be seen by other events
  roundTable =     {}
  witnessesTable = {}
  tbd = [] # Stores events which's order has yet to be determined
  
  ########## Private
  log = (args...) ->
    console.log(options.logPrefix, args...)
  
  error = (error) ->
    console.error(options.logPrefix, error.stack || error)
  
  # An "Event" in this implementation is an ipfs object
  # event = {Data: {c: peerId, t: unixTime, d: payload}, Links: [{Name: '', Hash: ''}]}
  publishEvent = (ownParentHash, otherParentHash, myPeerID, unixTimestamp, payload) ->
    object = {}
    object.Data = JSON.stringify(c: myPeerID, t: unixTimestamp, d: payload)
    object.Links = []
    object.Links.push({Name: '0', Hash: ownParentHash}) if ownParentHash
    object.Links.push({Name: '1', Hash: otherParentHash}) if otherParentHash
    ipfs.putObject(JSON.stringify(object))
    
  getParents = co.wrap (hash) ->
    event = getEvent(hash)
    return (link['Hash'] for link in event['Links'])
    
  highest = (hash1, hash2) ->
    if higher(hash1, hash2) then hash1 else hash2
    
  higher = (hash1, hash2) ->
    hash1 && hash2 && height[hash1] >= height[hash2]
    
  getEvent = co.wrap (hash) ->
    # TODO: cache in memory
    yield ipfs.pin(hash)
    json = yield ipfs.getObject(hash)
    return JSON.parse(json)
    
  setHead = (hash) ->
    new Promise (resolve, reject) ->
      ipfs.publish(hash)
        .then ->
          head = hash
          resolve()
        .catch reject
  
  getHead = (peerID = myPeerID) ->
    ipfs.resolve(peerID)
  
  getStake = (nodeId) ->
    return 1
  
  minStake = () ->
    # Such byzantine. Very fairness. Wow.
    Math.ceil(knownPeerIDs.length * 2 / 3)
  
  stronglySeen = (eventHash, r) ->
    hits = {}
    for c, k in canSeeTable[eventHash]
      if roundTable[k] == r
        for c2, k2 in canSeeTable[k]
          if roundTable[k2] == r
            hits[c2] = 0 unless hits[c2]?
            hits[c2] += getStake(c)
    return (c for c, n of hits when n > minStake())

  
  mainLoop = co.wrap ->
    c = knownPeerIDs.rand()
    if (c)
      log('Start Sync with', c)
      newEvents = yield sync(c).catch error
      if newEvents
        divideRounds(newEvents)
        newC = decideFame()
        findOrder(newC)
        # TODO: emit consensus event
    else
      log('no nodes to sync')
    setTimeout((-> mainLoop().catch(error)), 1000) if running
  
  divideRounds = (newEventHashes) ->
    for eventHash in newEventHashes
      event = getEvent(eventHash)
      eventNodeId = event.Data.c
      canSeeTable[eventHash] = {"#{eventNodeId}": eventHash}
      
      if event.Links.length == 0 # root event
        roundTable[eventHash] = 0
        witnessesTable[0] = {} unless witnessesTable[0]?
        witnessesTable[0][eventNodeId] = eventHash
      else
        r = Math.max(event.Links[0].Hash, event.Links[1].Hash)
        
        p0 = canSeeTable[event.Links[0].Hash]
        p1 = canSeeTable[event.Links[1].Hash]
        
        for nodeId in Object.keys(p0)
          canSeeTable[eventHash][nodeId] = highest(p0[nodeId], p1[nodeId])
        for nodeId in Object.keys(p1)
          canSeeTable[eventHash][nodeId] = highest(p0[nodeId], p1[nodeId])
        
        if stronglySeen(eventHash, r).length > minStake()
          roundTable[eventHash] = r + 1
        else
          roundTable[eventHash] = r
          
        if roundTable[eventHash] > roundTable[event.Links[0].Hash]
          witnessesTable[roundTable[eventHash]] = {} unless witnessesTable[roundTable[eventHash]]?
          witnessesTable[roundTable[eventHash]][eventNodeId] = eventHash
  
  decideFame = ->
    [] # TODO
    
  findOrder = (newC) ->
    true # TODO
  
  assert = (assertion) ->
    assertion # TODO
    
  # An event is only valid if either:
  # 1. It has no parents
  # 2. The node of the first parent event is the event's node
  eventIsValid = co.wrap (eventHash) ->
    event = getEvent(eventHash)
    
    return true if event.Links.length == 0
    
    ownParentEvent = yield getEvent(event.Links[0].Hash)
    otherParentEvent = yield getEvent(event.Links[1].Hash)
    
    return ownParentEvent.Data.c == event.Data.c && otherParentEvent.Data.c != event.Data.c
    
  pinEvent = (event) ->
    ipfs.pin(event)
  
  sync = co.wrap (remoteNodeId) ->
    remoteHead = yield getHead(remoteNodeId)
    newEventHashes = yield bfs remoteHead, co.wrap (u) -> (p for p in yield(getParents(u)) when !heightTable[p]?)
    
    for newEventHash in newEventHashes
      assert yield eventIsValid(newEventHash)
      
      tbd.add(newEventHash)
      p = yield(getParents(newEventHash))
      if p.length == 0
        heightTable[newEventHash] = 0
      else
        heightTable[newEventHash] = Math.max(heightTable[p[0]], heightTable[p[1]]) + 1
      
    ownNewEventHash = yield publishEvent(head, remoteHead, myPeerID, new Date().getTime() / 1000, payloadsForNextSync)
    payloadsForNextSync = []
    yield setHead(ownNewEventHash)
    
    newEventHashes.push(ownNewEventHash)
    return newEventHashes
    
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

    else
      log("Initializing a new Hashgraph Repo in #{path}")
      yield ipfs.init()
      info = yield ipfs.getPeerInfo()
      myPeerID = info.ID
      hash = yield publishEvent(null, null, myPeerID, new Date().getTime() / 1000, [])
      yield setHead(hash)
      
    hashgraph.emit('ready')
    Promise.resolve(hashgraph)
  
  hashgraph.start = ->
    return if running
    running = true
    mainLoop().catch error
    
  hashgraph.stop = ->
    running = false
          
  hashgraph.sendTransaction = (payload) -> 
    sendTransaction(payload)
  
  hashgraph.join = (peerID) ->
    knownPeerIDs.push(peerID)
      
  
  return hashgraph


module.exports = hashgraph
