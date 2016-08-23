###
Protocol references:
BitTorrent Specification: https://wiki.theory.org/index.php/BitTorrentSpecification
UDP Tracker Extension: http://www.rasterbar.com/products/libtorrent/udp_tracker_protocol.html
###

# https://github.com/WizKid/node-bittorrent-tracker
# https://github.com/feross/webtorrent

https = require('https')
dgram = require('dgram')
fs = require('fs')
path = require('path')
url = require('url')
querystring = require('querystring')
# The HTTP/HTTPS trakcer protocol specifies `info_hash` and `peer_id` to be "urlencoded" (as in HTML standard's `application/x-www-form-urlencoded`).
# To correctly decode them, JavaScript's `unescape` (global function) must be used instead of `decodeURIComponent` (default for `querystring.unescape`).
# See also: https://github.com/feross/bittorrent-tracker/issues/32
querystring.escape = escape
querystring.unescape = unescape
# Workaround for Int64, which JavaScript doesn't support natively
Long = require('long')
config = require('./config.json')
config.httpsops = 
  key: fs.readFileSync(path.resolve(config.httpskey))
  cert: fs.readFileSync(path.resolve(config.httpscert))

EVENT = ['', 'completed', 'started', 'stopped']
HEADERLEN = 8
CONNREQLEN = 16
CONNRESLEN = 16
ANNREQLEN = 98
ANNRESMIN = 20
ANNRESSTEP = 6
ANNRESMAX = ANNRESMIN + ANNRESSTEP * 74

JOBINIT = 0
JOBCONNREQ = 1
JOBCONNRES = 2
JOBANNREQ = 3
JOBANNRES = 4
JOBDONE = 5
JOBERR = 6
STATUS = [
  'client request received',
  'connecting tracker',
  'tracker connected',
  'announcing to tracker',
  'announce response received',
  'success',
  'error']

parseIPv4 = (str) ->
  octets = str.split('.')
  return undefined if octets.length != 4
  for o, i in octets
    o = parseInt(o)
    return undefined if isNaN(o) or o < 0 or o > 0xff
    octets[i] = o
  return new Buffer(octets)

###
Source:
https://github.com/Sebmaster/node-libbencode
###
bencode = (data, prev) ->
  prev ?= new Buffer(0)
  switch typeof data
    when 'number'
      str = 'i' + data + 'e'
      next = new Buffer(prev.length + Buffer.byteLength(str))
      prev.copy(next)
      next.write(str, prev.length)
    when 'string'
      str = Buffer.byteLength(data) + ':' + data
      next = new Buffer(prev.length + Buffer.byteLength(str))
      prev.copy(next)
      next.write(str, prev.length, 'binary')
    when 'object'
      if data instanceof Array
        next = new Buffer(prev.length + 1)
        prev.copy(next);
        next.write('l', prev.length, 'binary')
        prev = next
        for i in data
          prev = bencode(data[i], prev)
        next = new Buffer(prev.length + 1)
        prev.copy(next)
        next.write('e', prev.length, 'binary')
      else if data instanceof Buffer
        str = data.length + ':'
        next = new Buffer(prev.length + Buffer.byteLength(str) + data.length)
        prev.copy(next)
        next.write(str, prev.length)
        data.copy(next, prev.length + Buffer.byteLength(str))
      else
        next = new Buffer(prev.length + 1)
        prev.copy(next)
        next.write('d', prev.length, 'binary')
        prev = next
        for i of data
          prev = bencode(i, prev)
          prev = bencode(data[i], prev)
        next = new Buffer(prev.length + 1)
        prev.copy(next)
        next.write('e', prev.length, 'binary')
  return next

class Job
  constructor: (@req, @res, @trackergate) ->
    @id = @report(JOBINIT)
    if err = @parseReq()
      @resError(400, err) # 400 Bad Request
    else if err = @authReq()
      @resError(403, err) # 403 Forbidden (not sending 401 Unauthorized or 407 Proxy Authentication Required since both require an authentication challenge via WWW-Authenticate)
    if err
      console.log(':', @req.connection.remoteAddress + ':' + @req.connection.remotePort, @req.url)
      return @reqerr = err

  report: (status) ->
    date = Date.now()
    @status = status
    return @trackergate.recReport(date, @)

  parseReq: () ->
    parse = url.parse(@req.url)
    path = parse['pathname'].split('/') # ['', gatewayauth, trackerhost, trackerport, 'announce']
    return 'Invalid request path' if path.length != 5 or path[0] != '' or path[4] != 'announce'
    @gatewayauth = path[1]
    @trackerhost = path[2]
    return 'Invalid tracker hostname' if @trackerhost == ''
    @trackerport = parseInt(path[3])
    return 'Invalid tracker port' if isNaN(@trackerport) or @trackerport < 0 or @trackerport > 0xffff
    @annreq = {}
    query = querystring.parse(parse['query']) # {info_hash, peer_id, downloaded, left, uploaded, event, ip, key, numwant, port}
    @annreq.infohash = new Buffer(query['info_hash'] or '', 'binary')
    return 'Invalid info hash' if @annreq.infohash.length != 20
    @annreq.peerid = new Buffer(query['peer_id'] or '', 'binary')
    return 'Invalid peer ID' if @annreq.peerid.length != 20
    @annreq.downloaded = Long.fromString(query['downloaded'] or '-1')
    return 'Invalid downloaded bytes' if @annreq.downloaded.isNegative()
    @annreq.left = Long.fromString(query['left'] or '-1')
    return 'Invalid left bytes' if @annreq.left.isNegative()
    @annreq.uploaded = Long.fromString(query['uploaded'] or '-1')
    return 'Invalid uploaded bytes' if @annreq.uploaded.isNegative()
    @annreq.event = EVENT.indexOf(query['event'] or '')
    return 'Invalid announce event' if @annreq.event < 0
    @annreq.ip = parseIPv4(query['ip'] or @req.connection.remoteAddress) # only IPv4 supported for now
    return 'Invalid client IP' if @annreq.ip == undefined
    @annreq.key = parseInt(query['key'] or '0', 16)
    return 'Invalid announce key' if isNaN(@annreq.key) or @annreq.key < 0 or @annreq.key > 0xffffffff
    @annreq.numwant = parseInt(query['numwant'] or '-1')
    return 'Invalid number of wanted peers' if isNaN(@annreq.numwant) or @annreq.numwant < -1 or @annreq.numwant > 0x7fffffff
    @annreq.port = parseInt(query['port'])
    return 'Invalid client port' if isNaN(@annreq.port) or @annreq.numwant < 0 or @annreq.port > 0xffff
    console.log('>', '#' + @id, @req.connection.remoteAddress + ':' + @req.connection.remotePort, @trackerhost + ':' + @trackerport, @annreq.infohash.toString('hex'))
    return null

  authReq: () ->
    ## more sophisticated authentication with consideration to (user, client, tracker, infohash) to come
    return 'Gateway authentication failed' if @gatewayauth != config.passkey
    return null

  reqConnect: () ->
    data = new Buffer(CONNREQLEN)
    data.write('0000041727101980', 0, 8, 'hex') # protocol ID
    data.writeUInt32BE(0, 8) # action
    transid = @id * 2
    data.writeUInt32BE(transid, 12)
    onReqConnect = (err, bytes) =>
      return @resError(500, 'Error connecting to tracker: ' + err.message) if err # 500 Internal Server Error
      @report(JOBCONNREQ)
    @trackergate.udpserver.send(data, 0, CONNREQLEN, @trackerport, @trackerhost, onReqConnect)
    return null

  parseConnRes: (data) ->
    return @resError(502, 'Invalid connect response from tracker') if data.length < CONNRESLEN # 502 Bad Gateway
    @connid = new Buffer(8)
    data.copy(@connid, 0, 8, 16)
    return null

  reqAnnounce: () ->
    data = new Buffer(ANNREQLEN)
    @connid.copy(data, 0)
    data.writeUInt32BE(1, 8) # action
    transid = @id * 2 + 1
    data.writeUInt32BE(transid, 12)
    @annreq.infohash.copy(data, 16)
    @annreq.peerid.copy(data, 36)
    data.writeUInt32BE(@annreq.downloaded.getHighBitsUnsigned(), 56)
    data.writeUInt32BE(@annreq.downloaded.getLowBitsUnsigned(), 60)
    data.writeUInt32BE(@annreq.left.getHighBitsUnsigned(), 64)
    data.writeUInt32BE(@annreq.left.getLowBitsUnsigned(), 68)
    data.writeUInt32BE(@annreq.uploaded.getHighBitsUnsigned(), 72)
    data.writeUInt32BE(@annreq.uploaded.getLowBitsUnsigned(), 76)
    data.writeUInt32BE(@annreq.event, 80)
    @annreq.ip.copy(data, 84)
    data.writeUInt32BE(@annreq.key, 88)
    data.writeInt32BE(@annreq.numwant, 92)
    data.writeUInt16BE(@annreq.port, 96)
    onReqAnnounce = (err, bytes) =>
      return @resError(500, 'Error announcing to tracker: ' + err.message) if err # 500 Internal Server Error
      @report(JOBANNREQ)
    @trackergate.udpserver.send(data, 0, ANNREQLEN, @trackerport, @trackerhost, onReqAnnounce)
    return null

  parseAnnRes: (data) ->
    peerslen = data.length - ANNRESMIN
    return @resError(502, 'Invalid announce response from tracker') if data.length < ANNRESMIN or (peerslen) % ANNRESSTEP != 0 # 502 Bad Gateway
    @annres = {}
    @annres.interval = data.readUInt32BE(8)
    @annres.incomplete = data.readUInt32BE(12)
    @annres.complete = data.readUInt32BE(16)
    @annres.peers = new Buffer(peerslen)
    data.copy(@annres.peers, 0, ANNRESMIN)
    return null

  resAnnounce: () ->
    @trackergate.endJob(@)
    @res.writeHead(200) # 200 OK
    @res.write(bencode(@annres), 'binary')
    @res.end()
    @report(JOBDONE)
    console.log('<', '#' + @id, 'S/L/P', @annres.complete, @annres.incomplete, @annres.peers.length / ANNRESSTEP)
    return @id

  parseErrRes: (job, data) ->
    msglen = data.length - HEADERLEN
    @trackererr = new Buffer(msglen)
    data.copy(@trackererr, 0, HEADERLEN)
    return null

  resError: (code, msg) ->
    @trackergate.endJob(@)
    @res.writeHead(code, msg)
    @res.write(bencode({'failure reason': msg}))
    @res.end()
    @report(JOBERR)
    console.log('-', '#' + @id, code, msg)
    return @id

  expireReq: (msg) ->
    return @resError(504, msg) # 504 Gateway Timeout

class TrackerGate
  constructor: (@httpsops, @httpsport, @udpport, @trackertimeout) ->
    @jobqueue = {}
    @repqueue = []
    @httpsserver = https.createServer(@httpsops, @resClient)
    @udpserver = dgram.createSocket('udp4', @resTracker)
    onHTTPSClientError = (err, secpair) =>
      console.log('! HTTPS:', err) ## not sure how to get client address and port, see: http://stackoverflow.com/questions/25257709
    onUDPError = (err) =>
      console.log('! UDP:', err)
    @httpsserver.on('clientError', onHTTPSClientError)
    @udpserver.on('error', onUDPError)

  genID: () ->
    while not jobid or jobid of @jobqueue
      jobid = Math.floor(Math.random() * 0x80000000)
    return jobid

  recReport: (date, job) ->
    jobid = job.id or @genID()
    status = job.status
    rep = [date, jobid, status]
    @repqueue.push(rep)
    console.log(new Date(date).toISOString(), '#' + jobid, status, STATUS[status])
    return jobid

  endJob: (job) ->
    delete @jobqueue[job.id]
    return null

  resClient: (req, res) =>
    job = new Job(req, res, @)
    return job.reqerr if job.reqerr
    @jobqueue[job.id] = job
    job.reqConnect()
    return null

  resTracker: (msg, rinfo) =>
    return 'Tracker response too short' if msg.length < HEADERLEN
    action = msg.readUInt32BE(0)
    transid = msg.readUInt32BE(4)
    jobid = Math.floor(transid / 2)
    job = @jobqueue[jobid]
    return 'Tracker response not matching any client request' if not job
    switch action
      when 0 # connect
        job.report(JOBCONNRES)
        job.parseConnRes(msg)
        job.reqAnnounce()
      when 1 # announce
        job.report(JOBANNRES)
        job.parseAnnRes(msg)
        job.resAnnounce()
      when 2 # scrape
        return 'Scrape not yet implemented' # so WTF does this response come from?
      when 3 # error
        job.parseErrRes(msg)
        job.resError(500, 'Tracker error: ' + job.trackererr) # 500 Internal Server Error
    return null

  tick: () =>
    date = Date.now()
    while @repqueue.length > 0 and date - @repqueue[0][0] >= @trackertimeout * 1000
      [date, jobid, status] = @repqueue.shift()
      job = @jobqueue[jobid]
      continue if not job or job.status != status
      switch status
        when JOBCONNREQ
          job.expireReq('Tracker connect timeout')
        when JOBANNREQ
          job.expireReq('Tracker announce timeout')
    return null

  run: () ->
    @httpsserver.listen(@httpsport, '0.0.0.0')
    @udpserver.bind(@udpport)
    setInterval(@tick, 1000)

new TrackerGate(config.httpsops, config.httpsport, config.udpport, config.trackertimeout).run()
