// Generated by CoffeeScript 1.7.1
var OPEN, WebSocketServer, addDownServer, app, bodyParser, downServers, env, express, gatewayMessage, removeDownServer, request, send, serverId, start, wss, _, _ref;

_ref = require('ws'), WebSocketServer = _ref.Server, OPEN = _ref.OPEN;

request = require('request');

express = require('express');

bodyParser = require('body-parser');

env = require('./env');

wss = new WebSocketServer({
  port: env.wssPort
});

_ = require('lodash');

process.on('uncaughtException', function(err) {
  return console.log(err);
});

serverId = 1;

app = express();

app.use(bodyParser());

downServers = {};

addDownServer = function(gatewayServerId) {
  console.log('server down %s', gatewayServerId);
  return downServers[gatewayServerId] = true;
};

removeDownServer = function(gatewayServerId) {
  console.log('server up %s', gatewayServerId);
  return delete downServers[gatewayServerId];
};

gatewayMessage = function(userId, type, params, success, fail) {
  var gatewayServerId;
  if (fail == null) {
    fail = null;
  }
  gatewayServerId = env.gatewayForUser(userId);
  if (downServers[gatewayServerId]) {
    return typeof fail === "function" ? fail('down') : void 0;
  } else {
    return request({
      url: "http://" + env.gatewayServers[gatewayServerId] + "/" + type,
      method: 'post',
      form: params
    }, function(error, response, body) {
      if (error) {
        addDownServer(gatewayServerId);
        return typeof fail === "function" ? fail('down') : void 0;
      } else {
        return success(body);
      }
    });
  }
};

send = function(ws, message) {
  if (ws.readyState === OPEN) {
    return ws.send(message);
  } else {
    return console.log('WebSocket not open');
  }
};

start = function() {
  var socketsByClientId;
  console.log('started');
  app.listen(env.httpPort);
  app.post('/update', function(req, res) {
    var clientId, ws, _i, _len, _ref1;
    _ref1 = req.body.clientIds;
    for (_i = 0, _len = _ref1.length; _i < _len; _i++) {
      clientId = _ref1[_i];
      ws = socketsByClientId[clientId];
      if (ws) {
        if (ws.readyState === OPEN) {
          send(ws, "u" + req.body.userId + "\t" + req.body.changes);
        } else {
          delete socketsByClientId[clientId];
        }
      }
    }
    return res.send('');
  });
  app.post('/gateway/started', function(req, res) {
    var clientId, ws;
    removeDownServer(req.body.serverId);
    for (clientId in socketsByClientId) {
      ws = socketsByClientId[clientId];
      send(ws, '.');
    }
    return res.send('ok');
  });
  socketsByClientId = {};
  return wss.on('connection', function(ws) {
    var clientId, onError, setClientId;
    clientId = null;
    onError = function() {
      return ws.send(',');
    };
    setClientId = function(c) {
      console.log('client id %s', c);
      clientId = c;
      return socketsByClientId[clientId] = ws;
    };
    ws.on('close', function() {
      var e, gatewayServer, _i, _len, _ref1;
      _ref1 = env.gatewayServers;
      for (_i = 0, _len = _ref1.length; _i < _len; _i++) {
        gatewayServer = _ref1[_i];
        try {
          request({
            url: "http://" + gatewayServer + "/unsubscribe",
            method: 'post',
            form: {
              clientId: clientId
            }
          });
        } catch (_error) {
          e = _error;
          console.log('error');
        }
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
          return gatewayMessage(userId, 'init', {
            serverId: serverId,
            clientId: clientId,
            userId: userId
          }, function(body) {
            return send(ws, "I" + body);
          }, onError);
        case 'u':
          parts = message.split('\t');
          updateToken = parts[0].substr(1);
          userId = parts[1];
          changes = parts[2];
          return gatewayMessage(userId, 'update', {
            serverId: serverId,
            updateToken: updateToken,
            clientId: clientId,
            userId: userId,
            changes: changes
          }, function(body) {
            return send(ws, "U" + body);
          }, onError);
        case 's':
          parts = message.split('\t');
          userId = parts[0].substr(1);
          object = parts[1];
          return gatewayMessage(userId, 'subscribe', {
            serverId: serverId,
            clientId: clientId,
            userId: userId,
            object: object
          }, function(body) {
            return send(ws, "S" + userId + "\t" + object + "\t" + body);
          }, onError);
        case 'z':
          parts = message.split('\t');
          userId = parts[0].substr(1);
          object = parts[1];
          return gatewayMessage(userId, 'unsubscribe', {
            serverId: serverId,
            clientId: clientId,
            userId: userId,
            object: object
          }, function(body) {
            return send(ws, "Z" + userId + "\t" + object);
          }, onError);
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
              return gatewayMessage(userId, 'retrieve', {
                serverId: serverId,
                userId: userId,
                clientId: clientId,
                records: toRetrieve
              }, function(body) {
                r.push(userId);
                r.push(body);
                if (++done === count) {
                  return send(ws, "R" + (r.join('\t')));
                }
              }, onError);
            })(userId));
          }
          return _results;
      }
    });
  });
};

env.init(function() {
  var count, gatewayServer, id, num, _ref1, _results;
  count = 0;
  num = _.size(env.gatewayServers);
  _ref1 = env.gatewayServers;
  _results = [];
  for (id in _ref1) {
    gatewayServer = _ref1[id];
    _results.push(request({
      url: "http://" + gatewayServer + "/port/started",
      method: 'post',
      form: {
        serverId: serverId
      }
    }, function(error) {
      if (error) {
        addDownServer(id);
      }
      if (++count === num) {
        return start();
      }
    }));
  }
  return _results;
});
