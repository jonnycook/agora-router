Raven = require 'raven'
Raven.config('https://3301e76fd40f474f9a68d3b653069bc0:35e408f3ae38455dabf71add1e965649@sentry.io/135685').install()

{Server:WebSocketServer, OPEN:OPEN} = require('ws')
request = require 'request'
express = require 'express'
bodyParser = require 'body-parser'
env = require './env'
wss = new WebSocketServer port:env.wssPort
_ = require 'lodash'
mysql = require 'mysql'

gatewayServers = gatewayForUser = null

if env.customGateways
	gatewayServers = env.gatewayServers
	gatewayForUser = env.gatewayForUser
else
	connection = mysql.createConnection
		host: '50.116.31.117'
		user: 'root'
		password: 'ghijkk56k'
		database: 'agora'

	connection.connect()

	gatewayByUserId = {}
	gatewayServers =
		1:'50.116.26.9:3000'
		2:'198.58.119.227:3000'

	cbsForUser = {}
	gatewayForUser = (userId, cb) ->
		if gateway = gatewayByUserId[userId]
			cb gateway
		else
			if cbsForUser[userId]
				cbsForUser[userId].push cb
			else
				cbsForUser[userId] = [cb]
				connection.query "SELECT gateway_server FROM m_users WHERE id = #{userId}", (err, rows) ->
					if err
						console.log 'failed to find user', userId, err
						for cb in cbsForUser[userId]
							cb false
						delete cbsForUser[userId]
					else
						gateway = gatewayByUserId[userId] = rows[0].gateway_server
						for cb in cbsForUser[userId]
							cb gateway
						delete cbsForUser[userId]

process.on 'uncaughtException', (err) -> 
  console.log err

serverId = env.serverId

app = express()
app.use bodyParser()

downServers = {}
addDownServer = (gatewayServerId) ->
	console.log 'server down %s', gatewayServerId
	downServers[gatewayServerId] = true

removeDownServer = (gatewayServerId) ->
	console.log 'server up %s', gatewayServerId
	delete downServers[gatewayServerId]

gatewayMessage = (userId, type, params, success, fail=null) ->
	console.log type
	console.log 'doing', type
	gatewayForUser userId, (gatewayServerId) ->
		if gatewayServerId == false
			fail? 'no user'
		else
			if downServers[gatewayServerId]
				fail? 'down', gatewayServerId
			else
				startTime = new Date().getTime()
				request {
					url: "http://#{gatewayServers[gatewayServerId]}/#{type}",
					method: 'post'
					form:params
				}, (error, response, body) ->
					endTime = new Date().getTime()
					duration = (endTime - startTime)/1000
					if error
						console.log "error: #{userId} #{type} (#{duration})"
						# addDownServer gatewayServerId
						fail? 'down', gatewayServerId
					else
						console.log "request: #{userId} #{type} (#{duration})"
						success body, gatewayServerId

send = (ws, message) ->
	if ws
		if ws.readyState == OPEN
			ws.send message
		else
			console.log 'WebSocket not open'

start = ->
	console.log 'started'
	app.listen env.httpPort
	app.post '/update', (req, res) ->
		for clientId in req.body.clientIds
			ws = socketsByClientId[clientId]
			if ws
				if ws.readyState == OPEN
					send ws, "u#{req.body.userId}\t#{req.body.changes}"
				else
					delete socketsByClientId[clientId]
		res.send ''

	app.post '/sync', (req, res) ->
		for clientId in req.body.clientIds
			ws = socketsByClientId[clientId]
			if ws
				if ws.readyState == OPEN
					send ws, "Y#{req.body.userId}\t#{req.body.object}\t#{req.body.data}"
				else
					delete socketsByClientId[clientId]
		res.send ''

	app.post '/gateway/started', (req, res) ->
		# removeDownServer req.body.serverId
		for clientId, ws of socketsByClientId
			send ws, ".#{req.body.serverId}"
		res.send 'ok'

	nextCommandId = 0
	commandCbs = {}
	app.get '/command', (req, res) ->
		console.log req.query
		ws = socketsByClientId[req.query.clientId]
		commandId = nextCommandId++
		send ws, "$#{commandId}\t#{req.query.command}"
		timeoutId = setTimeout (->
			if commandCbs[commandId]
				res.send 'timeout'
				delete commandCbs[commandId]
		), 1000*15

		commandCbs[commandId] = (response) ->
			res.send response
			delete commandCbs[commandId] 

	app.get '/ping', ->
		for clientId, ws of socketsByClientId
			console.log "pinging #{clientId}..."
			ws.send "p#{clientId}"


	socketsByClientId = {}

	count = 0
	setInterval (->
		console.log "count: #{count}"
	), 1000*60

	nextNumber = 0
	wss.on 'connection', (ws) ->
		++ count
		wsNumber = nextNumber++
		console.log "[#{wsNumber}] opened (#{count})"
		clientId = null
		onError = (error, gatewayServerId) ->
			ws.send ",#{gatewayServerId}"

		setClientId = (c) ->
			console.log "[#{wsNumber}] client id #{c}"
			clientId = c
			socketsByClientId[clientId] = ws

		ws.on 'close', ->
			--count
			console.log "[#{wsNumber}] closed (#{count})"
			for id, gatewayServer of gatewayServers
				try
					request
						url: "http://#{gatewayServer}/unsubscribeClient",
						method:'post'
						form:
							clientId:clientId
							serverId:serverId
				catch e
					console.log 'error'
			delete socketsByClientId[clientId]

		ws.on 'message', (message) ->
			console.log "[#{wsNumber}] message: #{message}"
			messageType = message[0]
			message = message.substr 1

			switch messageType
				# message
				when 'm'
					[number, userId, type, params] = message.split '\t'
					params = if params then JSON.parse params else {}
					params.clientId = clientId
					params.userId = userId
					gatewayMessage userId, type, params, ((body) ->
						send ws, "<#{number}\t#{body}"),
						onError

				# init
				when 'i'
					[number, clientId, userId] = message.split '\t'
					setClientId clientId
					gatewayMessage userId, 'init',
						serverId:serverId
						clientId:clientId
						userId:userId
						(body, gatewayServerId) -> send ws, "<#{number}\t#{gatewayServerId}\t#{body}"
						onError

				# update
				when 'u'
					[number, updateToken, userId, changes] = message.split '\t'
					gatewayMessage userId, 'update',
						serverId:serverId
						updateToken:updateToken
						clientId:clientId
						userId:userId
						changes:changes
						(body) -> send ws, "<#{number}\t#{body}"
						onError		

				# subscribe
				when 's'
					[number, userId, object, key] = message.split '\t'
					gatewayMessage userId, 'subscribe',
						serverId:serverId
						clientId:clientId
						userId:userId
						object:object
						key:key
						(body, gatewayServerId) -> send ws, "<#{number}\t#{gatewayServerId}\t#{userId}\t#{object}\t#{body}"
						onError		

				# unsubscribe (z kind of looks like a backwards s... (u is already taken))
				when 'z'
					[number, userId, object] = message.split '\t'
					gatewayMessage userId, 'unsubscribe',
						serverId:serverId
						clientId:clientId
						userId:userId
						object:object
						(body) -> send ws, "<#{number}\t#{userId}\t#{object}"
						onError		

				# retrieve
				when 'r'
					parts = message.split('\t')
					number = parts[0]
					parts = parts.slice 1
					count = parts.length/2
					done = 0
					r = []
					for i in [0...count]
						userId = parts[i*2]
						toRetrieve = parts[i*2 + 1]
						do (userId) ->
							gatewayMessage userId, 'retrieve',
								serverId:serverId
								userId:userId
								clientId:clientId
								records:toRetrieve
								(body) ->
									r.push userId
									r.push body
									if ++done == count
										send ws, "<#{number}\t#{r.join '\t'}"
								onError	

				when 't'
					[userId, args...] = message.split '\t'
					gatewayMessage userId, 'track',
						serverId:serverId
						clientId:clientId
						# userId:userId
						args:args
						->
						onError

				when '$'
					[commandId, response] = message.split '\t'
					commandCbs[commandId]? response

				when 'P'
					console.log "[#{wsNumber}] ping received #{clientId} #{message}"


count = 0
num = _.size gatewayServers
for id,gatewayServer of gatewayServers
	request {
		url: "http://#{gatewayServer}/port/started",
		method:'post'
		form:
			serverId:serverId
	}, (error) ->
		if error
			addDownServer id
		if ++count == num
			start()
