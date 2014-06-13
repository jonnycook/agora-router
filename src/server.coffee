{Server:WebSocketServer, OPEN:OPEN} = require('ws')
request = require 'request'
express = require 'express'
bodyParser = require 'body-parser'
env = require './env'
wss = new WebSocketServer port:env.wssPort

# mysql = require 'mysql'
# env = require './env'


serverId = 1

app = express()
app.use bodyParser()

start = ->
	app.listen env.httpPort
	app.post '/update', (req, res) ->
		for clientId in req.body.clientIds
			ws = socketsByClientId[clientId]
			if ws
				if ws.readyState == OPEN
					ws.send "u#{req.body.userId}\t#{req.body.changes}"
				else
					delete socketsByClientId[clientId]
		res.send ''

	app.post '/gateway/started', (req, res) ->
		for clientId, ws of socketsByClientId
			ws.send '!'
		res.send 'ok'

	socketsByClientId = {}

	wss.on 'connection', (ws) ->
		clientId = null
		setClientId = (c) ->
			console.log 'client id %s', c
			clientId = c
			socketsByClientId[clientId] = ws

		ws.on 'close', ->
			for gatewayServer in env.gatewayServers
				request
					url: "http://#{gatewayServer}/unsubscribe",
					method:'post'
					form:
						clientId:clientId
			delete socketsByClientId[clientId]

		ws.on 'message', (message) ->
			console.log 'message: %s', message
			messageType = message[0]
			switch messageType
				# init
				when 'i'
					setClientId message.substr 1, 32
					userId = message.substr 33
					request {
						url: "http://#{env.gatewayForUser(userId)}/init",
						method: 'post'
						form:
							serverId:serverId
							clientId:clientId
							userId:userId
					}, (error, response, body) ->
						ws.send "I#{body}"

				# update
				when 'u'
					parts = message.split '\t'
					updateToken = parts[0].substr 1
					userId = parts[1]
					changes = parts[2]
					request {
						url: "http://#{env.gatewayForUser(userId)}/update",
						method: 'post'
						form:
							serverId:serverId
							updateToken:updateToken
							clientId:clientId
							userId:userId
							changes:changes
					}, (error, response, body) ->
						ws.send "U#{body}"

				# subscribe
				when 's'
					parts = message.split '\t'
					userId = parts[0].substr 1
					object = parts[1]
					request {
						url: "http://#{env.gatewayForUser(userId)}/subscribe",
						method:'post'
						form:
							serverId:serverId
							clientId:clientId
							userId:userId
							object:object
					}, (error, response, body) ->
						ws.send "S#{userId}\t#{object}\t#{body}"

				# unsubscribe (z kind of looks like a backwards s... (u is already taken))
				when 'z'
					parts = message.split '\t'
					userId = parts[0].substr 1
					object = parts[1]
					request {
						url: "http://#{env.gatewayForUser(userId)}/unsubscribe",
						method:'post'
						form:
							serverId:serverId
							clientId:clientId
							userId:userId
							object:object
					}, (error, response, body) ->
						ws.send "Z#{userId}\t#{object}"

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
							request {
								url: "http://#{env.gatewayForUser(userId)}/retrieve",
								method:'post'
								form:
									serverId:serverId
									userId:userId
									clientId:clientId
									records:toRetrieve
							}, (error, response, body) ->
								r.push userId
								r.push body
								if ++done == count
									ws.send "R#{r.join '\t'}"


env.init ->
	count = 0
	for gatewayServer in env.gatewayServers
		request {
			url: "http://#{gatewayServer}/port/started",
			method:'post'
			form:
				serverId:serverId
		}, ->
			if ++count == env.gatewayServers.length
				start()
