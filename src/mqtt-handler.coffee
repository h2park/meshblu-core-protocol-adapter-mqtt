MultiHydrantFactory = require 'meshblu-core-manager-hydrant/multi'
debug = require('debug')('meshblu-core-protocol-adapter-mqtt:handler')
async = require 'async'
_     = require 'lodash'

class MQTTHandler
  constructor: ({@client, @jobManager, @messengerFactory, @server}) ->
    @JOB_MAP =
      'meshblu/request'  : @handleMeshbluRequest
      'meshblu/firehose' : @handleMeshbluFirehose
    @messengers = {}

  authenticateClient: (uuid, token, callback) =>
    auth = {uuid, token}
    @client.auth = auth
    return callback null, true unless uuid?
    @authenticateMeshblu auth, callback

  authenticateMeshblu: (auth, callback) =>
    request = metadata: {jobType: 'Authenticate', auth}
    @jobManager.do 'request', 'response', request, (error, response) =>
      return callback error if error?
      return callback new Error('meshblu not authenticated') unless response?.metadata?.code == 204
      return callback null, true

  handleMeshbluFirehose: (packet) =>
    payload = @_parsePayload(packet)
    auth = payload?.auth or @client.auth
    @authenticateMeshblu auth, (error, success) =>
      return @_emitError(error, packet) if error? or !success
      @messengers[auth.uuid]?.close()
      if payload?.connect
        return @_connectFirehose auth, payload, packet
      else
        return @_emitPayload 'firehose', {connected: false}, payload

  _connectFirehose: (auth, payload, packet) =>
    {uuid} = auth
    return unless uuid?
    @messengers[uuid] = @_buildMessenger(payload.replyTopic)
    @messengers[uuid].connect (error) =>
      return @_emitError(error, packet) if error?
      async.each ['received', 'config'], (type, next) =>
        @messengers[uuid].subscribe {type, uuid: auth.uuid}, next
      , (error) =>
        return @_emitError(error, packet) if error?
        return @_emitPayload 'firehose', {connected: true}, payload

  handleMeshbluRequest: (packet) =>
    debug 'doing meshblu request...', packet
    payload = @_parsePayload(packet)
    debug 'with packet', payload
    return @_emitError(new Error('undefined job type'), packet) unless payload?.job?.metadata?.jobType?

    payload.job.metadata.auth ?= @client.auth
    debug 'request job:', payload.job
    @jobManager.do 'request', 'response', payload.job, (error, response) =>
      debug 'response received:', response
      @_emitResponse response, payload

  onPublished: (packet) =>
    debug 'onPublished'
    topic = packet.topic
    fn = @JOB_MAP[topic]
    return @_emitError(new Error("Topic '#{topic}' is not valid"), packet) unless _.isFunction fn
    fn(packet)

  onClose: =>
    _.forEach @messengers, (messenger) =>
      messenger?.close()

  _parsePayload: (packet) =>
    try
      return JSON.parse packet?.payload
    catch error
      return

  _buildMessenger: (replyTopic) =>
    messenger = @messengerFactory.build()
    messenger.on 'message', (channel, message) =>
      @_emitPayload 'message', message, {replyTopic, callbackId:false}
    messenger.on 'config', (channel, message) =>
      @_emitPayload 'config', message, {replyTopic, callbackId:false}
    return messenger

  _emitResponse: (response, payload) =>
    response ?= metadata:
      code: 500
      status: 'null response from job manager'
    {metadata, rawData:data} = response
    if metadata?.code >= 300
      type = 'error'
      data = metadata?.status
    data = undefined if data == 'null'
    @_emitPayload type, data, payload

  _emitError: (error, packet) =>
    @_emitPacket 'error', error?.message, packet

  _emitPacket: (type, data, packet) =>
    payload = @_parsePayload(packet) or {}
    @_emitPayload type, data, payload

  _emitPayload: (type, data, payload) =>
    {replyTopic:topic, callbackId} = payload
    payload = {type, data, callbackId}
    debug 'emitPayload', {payload}
    @_clientPublish topic, payload if callbackId?

  _clientPublish: (topic, payload) =>
    topic ?= "meshbluClient/#{@client?.auth?.uuid or 'guest'}/#{@client?.id}"
    payload.type = "meshblu/#{payload.type or 'response'}"
    packet = {topic, payload: JSON.stringify(payload)}
    debug 'clientPublish:', packet
    @client.connection.publish packet

module.exports = MQTTHandler
