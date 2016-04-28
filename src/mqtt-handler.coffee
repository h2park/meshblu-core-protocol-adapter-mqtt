debug = require('debug')('meshblu-core-protocol-adapter-mqtt:handler')
async = require 'async'
_     = require 'lodash'

class MQTTHandler
  constructor: ({@client, @jobManager, @messengerFactory, @server}) ->
    @JOB_MAP =
      'meshblu.request'          : @handleMeshbluRequest
      'meshblu.authenticate'     : @handleMeshbluAuthenticateClient
      'meshblu.firehose.request' : @handleMeshbluFirehoseRequest

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

  _buildMessenger: =>
    messenger = @messengerFactory.build()
    messenger.on 'message', (channel, message) =>
      @_emitEvent 'message', message
    messenger.on 'config', (channel, message) =>
      @_emitEvent 'config', message

  handleMeshbluFirehoseRequest: (packet) =>
    payload = @parsePayload(packet)
    auth = payload?.auth or @client.auth
    @authenticateMeshblu auth, (error, success) =>
      return @_emitError(error, packet) if error? or !success
      @messenger = @_buildMessenger()
      @messenger.connect (error) =>
        return @_emitError(error, packet) if error?
        async.each ['received', 'config'], (type, next) =>
          @messenger.subscribe {type, uuid: auth.uuid}, next
        , (error) =>
          return @_emitError(error, packet) if error?
          return @_emitEvent 'meshblu.firehose.request', {firehose: true}, packet

  _verifyMeshbluJob: (payload) =>
    return false unless payload?
    return false unless _.isObject payload?.job?.metadata
    return false unless payload.job.metadata.jobType?
    return true

  handleMeshbluRequest: (packet) =>
    debug 'doing meshblu request...', packet
    payload = @parsePayload(packet)
    return @_emitError(new Error('invalid job'), packet) unless @_verifyMeshbluJob payload

    payload.job.metadata.auth ?= @client.auth
    debug 'request job:', payload.job
    @jobManager.do 'request', 'response', payload.job, (error, response) =>
      debug 'response received:', response
      @_emitResponse response, payload

  handleMeshbluAuthenticateClient: (packet) =>

  onPublished: (packet) =>
    debug 'onPublished'
    topic = packet.topic
    fn = @JOB_MAP[topic]
    return @_emitError(new Error("Topic '#{topic}' is not valid"), packet) unless _.isFunction fn
    fn(packet)

  onClose: =>
    @messenger?.close()

  parsePayload: (packet) =>
    try
      return JSON.parse packet?.payload
    catch error
      return

  _emitResponse: (response, payload) =>
    response ?= metadata:
      code: 500
      status: 'null response from job manager'
    {topic:type, metadata, rawData:data} = response
    if metadata?.code >= 300
      type = 'error'
      data = metadata?.status
    @_emitPayload type, data, payload

  _emitError: (error, packet) =>
    @_emitEvent 'error', error?.message, packet

  _emitEvent: (type, data, packet) =>
    payload = @parsePayload(packet) or {}
    @_emitPayload type, data, payload

  _emitPayload: (type, data, payload) =>
    {replyTopic:topic, callbackId} = payload
    payload = {type, data, callbackId}
    @_clientPublish topic, payload

  _clientPublish: (topic, payload) =>
    topic ?= "#{@client?.auth?.uuid or 'guest'}/#{@client?.id}"
    payload.type ?= 'response'
    payload.type = "meshblu.#{payload.type}"
    payload = JSON.stringify payload
    packet = {topic, payload}
    debug 'clientPublish:', packet
    @client.connection.publish packet
    #@client.forward '', payload, {}, '', 0

module.exports = MQTTHandler
