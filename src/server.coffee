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
		fail? 'down'
	else
		request {
			url: "http://#{env.gatewayServers[gatewayServerId]}/#{type}",
			method: 'post'
			form:params
		}, (error, response, body) ->
			if error
				addDownServer gatewayServerId
				fail? 'down'
			else
				success body

send = (ws, message) ->
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

	app.post '/gateway/started', (req, res) ->
		removeDownServer req.body.serverId
		for clientId, ws of socketsByClientId
			send ws, '.'
		res.send 'ok'

	socketsByClientId = {}

	wss.on 'connection', (ws) ->
		clientId = null
		onError = ->
			ws.send ','

		setClientId = (c) ->
			console.log 'client id %s', c
			clientId = c
			socketsByClientId[clientId] = ws

		ws.on 'close', ->
			for gatewayServer in env.gatewayServers
				try
					request
						url: "http://#{gatewayServer}/unsubscribe",
						method:'post'
						form:
							clientId:clientId
				catch e
					console.log 'error'
			delete socketsByClientId[clientId]

		ws.on 'message', (message) ->
			console.log 'message: %s', message
			messageType = message[0]
			switch messageType
				# init
				when 'i'
					setClientId message.substr 1, 32
					userId = message.substr 33
					gatewayMessage userId, 'init',
						serverId:serverId
						clientId:clientId
						userId:userId
						(body) -> send ws, "I#{body}"		
						onError		

				# update
				when 'u'
					parts = message.split '\t'
					updateToken = parts[0].substr 1
					userId = parts[1]
					changes = parts[2]
					gatewayMessage userId, 'update',
						serverId:serverId
						updateToken:updateToken
						clientId:clientId
						userId:userId
						changes:changes
						(body) -> send ws, "U#{body}"
						onError		

				# subscribe
				when 's'
					parts = message.split '\t'
					userId = parts[0].substr 1
					object = parts[1]
					gatewayMessage userId, 'subscribe',
						serverId:serverId
						clientId:clientId
						userId:userId
						object:object
						(body) -> send ws, "S#{userId}\t#{object}\t#{body}"
						onError		

				# unsubscribe (z kind of looks like a backwards s... (u is already taken))
				when 'z'
					parts = message.split '\t'
					userId = parts[0].substr 1
					object = parts[1]
					gatewayMessage userId, 'unsubscribe',
						serverId:serverId
						clientId:clientId
						userId:userId
						object:object
						(body) -> send ws, "Z#{userId}\t#{object}"
						onError		

				# retrieve
				when 'r'
					parts = message.substr(1).split('\t')
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
										send ws, "R#{r.join '\t'}"
								onError		


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
