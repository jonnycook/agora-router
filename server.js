// Generated by CoffeeScript 1.7.1
(function() {
  var OPEN, WebSocketServer, app, bodyParser, count, express, gatewayForUser, gatewayServer, gatewayServers, request, serverId, start, wss, _i, _len, _ref;

  _ref = require('ws'), WebSocketServer = _ref.Server, OPEN = _ref.OPEN;

  wss = new WebSocketServer({
    port: 8080
  });

  request = require('request');

  express = require('express');

  bodyParser = require('body-parser');

  gatewayServers = ["localhost:3000"];

  gatewayForUser = function(userId) {
    return "localhost:3000";
  };

  serverId = 1;

  app = express();

  app.use(bodyParser());

  start = function() {
    var socketsByClientId;
    app.listen(3001);
    app.post('/update', function(req, res) {
      var clientId, ws, _i, _len, _ref1;
      _ref1 = req.body.clientIds;
      for (_i = 0, _len = _ref1.length; _i < _len; _i++) {
        clientId = _ref1[_i];
        ws = socketsByClientId[clientId];
        if (ws) {
          if (ws.readyState === OPEN) {
            ws.send("u" + req.body.userId + "\t" + req.body.changes);
          } else {
            delete socketsByClientId[clientId];
          }
        }
      }
      return res.send('');
    });
    app.post('/gateway/started', function(req, res) {
      var clientId, ws;
      for (clientId in socketsByClientId) {
        ws = socketsByClientId[clientId];
        ws.send('!');
      }
      return res.send('ok');
    });
    socketsByClientId = {};
    return wss.on('connection', function(ws) {
      var clientId, setClientId;
      clientId = null;
      setClientId = function(c) {
        console.log('client id %s', c);
        clientId = c;
        return socketsByClientId[clientId] = ws;
      };
      ws.on('close', function() {
        var gatewayServer, _i, _len;
        for (_i = 0, _len = gatewayServers.length; _i < _len; _i++) {
          gatewayServer = gatewayServers[_i];
          request({
            url: "http://" + gatewayServer + "/unsubscribe",
            method: 'post',
            form: {
              clientId: clientId
            }
          });
        }
        return delete socketsByClientId[clientId];
      });
      return ws.on('message', function(message) {
        var changes, count, done, i, messageType, object, parts, r, toRetrieve, updateToken, userId, _i, _results;
        console.log('message: %s', message);
        messageType = message[0];
        switch (messageType) {
          case 'i':
            setClientId(message.substr(1, 32));
            userId = message.substr(33);
            return request({
              url: "http://" + (gatewayForUser(userId)) + "/init",
              method: 'post',
              form: {
                serverId: serverId,
                clientId: clientId,
                userId: userId
              }
            }, function(error, response, body) {
              return ws.send("I" + body);
            });
          case 'u':
            parts = message.split('\t');
            updateToken = parts[0].substr(1);
            userId = parts[1];
            changes = parts[2];
            return request({
              url: "http://" + (gatewayForUser(userId)) + "/update",
              method: 'post',
              form: {
                serverId: serverId,
                updateToken: updateToken,
                clientId: clientId,
                userId: userId,
                changes: changes
              }
            }, function(error, response, body) {
              return ws.send("U" + body);
            });
          case 's':
            parts = message.split('\t');
            userId = parts[0].substr(1);
            object = parts[1];
            return request({
              url: "http://" + (gatewayForUser(userId)) + "/subscribe",
              method: 'post',
              form: {
                serverId: serverId,
                clientId: clientId,
                userId: userId,
                object: object
              }
            }, function(error, response, body) {
              return ws.send("S" + userId + "\t" + object + "\t" + body);
            });
          case 'z':
            parts = message.split('\t');
            userId = parts[0].substr(1);
            object = parts[1];
            return request({
              url: "http://" + (gatewayForUser(userId)) + "/unsubscribe",
              method: 'post',
              form: {
                serverId: serverId,
                clientId: clientId,
                userId: userId,
                object: object
              }
            }, function(error, response, body) {
              return ws.send("Z" + userId + "\t" + object);
            });
          case 'r':
            parts = message.substr(1).split('\t');
            count = parts.length / 2;
            done = 0;
            r = [];
            _results = [];
            for (i = _i = 0; 0 <= count ? _i < count : _i > count; i = 0 <= count ? ++_i : --_i) {
              userId = parts[i * 2];
              toRetrieve = parts[i * 2 + 1];
              _results.push((function(userId) {
                return request({
                  url: "http://" + (gatewayForUser(userId)) + "/retrieve",
                  method: 'post',
                  form: {
                    serverId: serverId,
                    userId: userId,
                    clientId: clientId,
                    records: toRetrieve
                  }
                }, function(error, response, body) {
                  r.push(userId);
                  r.push(body);
                  if (++done === count) {
                    return ws.send("R" + (r.join('\t')));
                  }
                });
              })(userId));
            }
            return _results;
        }
      });
    });
  };

  count = 0;

  for (_i = 0, _len = gatewayServers.length; _i < _len; _i++) {
    gatewayServer = gatewayServers[_i];
    request({
      url: "http://" + gatewayServer + "/port/started",
      method: 'post',
      form: {
        serverId: serverId
      }
    }, function() {
      if (++count === gatewayServers.length) {
        return start();
      }
    });
  }

}).call(this);
