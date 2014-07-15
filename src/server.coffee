{Server:WebSocketServer, OPEN:OPEN} = require('ws')
request = require 'request'
express = require 'express'
bodyParser = require 'body-parser'
env = require './env'
wss = new WebSocketServer port:env.wssPort
_ = require 'lodash'

# mysql = require 'mysql'
# env = require './env'

process.on 'uncaughtException', (err) -> 
  console.log err

serverId = 1

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
	gatewayServerId = env.gatewayForUser(userId)
	if downServers[gatewayServerId]
		fail? 'down', gatewayServerId
	else
		request {
			url: "http://#{env.gatewayServers[gatewayServerId]}/#{type}",
			method: 'post'
			form:params
		}, (error, response, body) ->
			if error
				# addDownServer gatewayServerId
				fail? 'down', gatewayServerId
			else
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


	socketsByClientId = {}

	wss.on 'connection', (ws) ->
		clientId = null
		onError = (error, gatewayServerId) ->
			ws.send ",#{gatewayServerId}"

		setClientId = (c) ->
			console.log 'client id %s', c
			clientId = c
			socketsByClientId[clientId] = ws

		ws.on 'close', ->
			for gatewayServer in env.gatewayServers
				try
					request
						url: "http://#{gatewayServer}/unsubscribeClient",
						method:'post'
						form:
							clientId:clientId
				catch e
					console.log 'error'
			delete socketsByClientId[clientId]

		ws.on 'message', (message) ->
			console.log 'message: %s', message
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


env.init ->
	count = 0
	num = _.size env.gatewayServers
	for id,gatewayServer of env.gatewayServers
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
