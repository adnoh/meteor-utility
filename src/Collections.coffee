global = @

Collections =

####################################################################################################
# COLLECTIONS
####################################################################################################

  # Queue used to prevent interferrence between asychronous use of collections. e.g. Only a single
  # collection can be created at a time.
  _queue: null

  allow: -> true
  allowAll: -> insert: @allow, update: @allow, remove: @allow

  # @param {Meteor.Collection|Cursor|String} arg
  # @returns {String}
  getName: (arg) ->
    collection = @get(arg)
    # Meteor.Collection or LocalCollection.
    if collection then (collection._name || collection.name) else null

  getTitle: (arg) ->
    name = @getName(arg)
    if name then Strings.toTitleCase(name) else name

  # @param {String|Meteor.Collection|Cursor} arg
  # @returns {Meteor.Collection|Cursor} Either a Meteor collection, a cursor, or null if none is
  #     found.
  get: (arg) ->
    if Types.isString(arg)
      # Collection name.
      global[arg]
    else if @isCursor(arg)
      arg.collection
    else if @isCollection(arg)
      arg
    else
      null

  # @param {String|Meteor.Collection|Cursor} arg
  # @returns The underlying Cursor or null if none is found.
  getCursor: (arg) ->
    if @isCursor(arg)
      arg
    else
      collection = @get(arg)
      if collection? then collection.find() else null

  # @param {String|Meteor.Collection|Cursor|SimpleSchema} arg
  # @returns {SimpleSchema}
  getSchema: (arg) ->
    collection = @get(arg)
    if @isCollection(collection)
      collection.simpleSchema()
    else if arg instanceof SimpleSchema
      arg
    else
      null

  # @param {*) obj
  # @returns {Boolean} Whether the given object is a collection.
  isCollection: (obj) -> 
    obj instanceof Meteor.Collection || obj instanceof Mongo.Collection ||
    # Packages may wrap the collection classes causing instanceof checks to fail, so we check the
    # raw underlying collection as well if it exists.
    obj instanceof LocalCollection || (obj?._collection? and @isCollection(obj._collection))

  # @param obj
  # @returns {Boolean} Whether the given object is a collection cursor.
  isCursor: (obj) -> obj && Types.isFunction(obj.fetch)

  # @param {Meteor.Collection|Cursor|Array} arg
  # @param {Object} [options]
  # @param {Object} [options.clone=true] - Whether to clone returned documents (default). If false,
  #     the document objects will be accessed directly from the IdMap if possible. This results in
  #     higher performance at the risk of exposing the mutable documents.
  # @returns {Array} The items in the collection, or the cursor, or the original array passed.
  getItems: (arg, options) ->
    if Types.isArray(arg)
      return arg
    if Types.isString(arg)
      arg = @get(arg)
    if @isCollection(arg)
      if options?.clone == false
        return _.values(arg._collection._docs._map)
      arg = arg.find({})
    if @isCursor(arg)
      return arg.fetch()
    return []

  # @param {Array.<Meteor.Collection>} collections
  # @returns {Object.<String, Meteor.Collection>} A map of collection name to object for the given
  #      collections.
  getMap: (collections) ->
    collectionMap = {}
    _.each collections, (collection) =>
      name = @getName(collection)
      collectionMap[name] = collection
    collectionMap

  # @param {Object.<String, String>} map - A map of IDs to names of the items.
  # @returns A temporary collection with items created from the given map.
  fromNameMap: (map, args) ->
    args = _.extend({
    }, args)
    collection = Collections.createTemporary()
    callback = args.callback
    _.each map, (item, id) ->
      if callback
        name = callback(item, id)
      else
        name = item
      collection.insert(_id: id, name: name)
    collection

  createTemporary: (docs) ->
    collection = new Meteor.Collection(null)
    @insertAll(docs, collection)
    collection

  isTemporary: (collection) -> !@getName(collection)

  # @returns {String} Generates a MongoDB ObjectID hex string.
  generateId: -> new Mongo.ObjectID().toHexString()

  intersection: (a, b) ->
    result = @createTemporary()
    a.find().forEach (item) ->
      if b.findOne(_id: item._id)
        result.insert(item)
    result

  # @param {Meteor.Collection|Cursor|String} collection
  # @param {Object|Function} args - If given as a function, it takes precendence as the callback
  #      for all event callbacks otherwise allowed.
  # @param {Function} [args.added]
  # @param {Function} [args.changed]
  # @param {Function} [args.removed]
  # @param {Function} [args.triggerExisting=false] - Whether to trigger the added callback for
  # existing docs.
  # @returns {Object} handle - A handle simliar to the return of the native observe().
  observe: (collection, args) ->
    observing = false
    if Types.isFunction(args)
      args = {added: args, changed: args, removed: args}
    args = _.extend({triggerExisting: false}, args)
    createHandler = (handler) ->
      -> handler.apply(@, arguments) if observing
    observeArgs = {}
    _.each ['added', 'changed', 'removed'], (methodName) ->
      handler = args[methodName]
      if handler
        observeArgs[methodName] = createHandler(handler)
    cursor = @getCursor(collection)
    handle = cursor.observe(observeArgs)
    observing = true
    if args.triggerExisting
      cursor.forEach (doc) -> observeArgs.added?(doc)
    handle

  # Copies docs from one collection to another and tracks changes in the source collection to apply
  # over time.
  # @param {Meteor.Collection|Cursor} src
  # @param {Meteor.Collection} [dest] - If none is provided, a temporary collection is used.
  # @param {Object} [args]
  # @param {Boolean} [args.track=true] - Whether to observe changes in the source and apply them to
  #     the destination over time.
  # @param {Boolean} [args.exclusive=false] - Whether to retain previous observations for copying.
  #     If true, the existing observation is stopped before the new one starts.
  # @param {Function} [args.beforeInsert] - A function which is passed each document from the source
  #     before it is inserted into the destination. If false is returned by this function, the
  #     insert is cancelled. If an object is returned, it is used as the document. Otherwise the
  #     source document passed to this function is used.
  # @param {Function} [args.afterInsert] - A function which is passed each document ID from the
  #     destination after it is inserted into the destination.
  # @returns {Promise} A promise containing the destination collection once all docs have been
  #     copied. The destination collection contains a stop() method for stopping the reactive sync.
  copy: (src, dest, args) ->
    args = _.extend({
      track: true,
      exclusive: false
    }, args)
    dest ?= @createTemporary()
    isSync = Meteor.isServer or Collections.isTemporary(dest)
    insertPromises = []

    beforeInsert = args.beforeInsert
    afterInsert = args.afterInsert
    insert = (srcDoc) =>
      df = Q.defer()
      if beforeInsert
        resultDoc = beforeInsert(srcDoc)
        if resultDoc == false
          return
        else if Types.isObjectLiteral(resultDoc)
          srcDoc = resultDoc
      # If inserting synchronously is possible, do so to ensure afterInsert is called before
      # any other code has a chance to run in case this is undesirable.
      if isSync
        try
          result = dest.insert(srcDoc)
          afterInsert?(result)
          df.resolve(result)
        catch err
          df.reject(err)
      else
        dest.insert srcDoc, (err, result) ->
          if err
            df.reject(err)
          else
            afterInsert?(result)
            df.resolve(result)
      df.promise
    # Collection2 may not allow inserting a doc into a collection with a predefined _id, so we
    # store a map of src to dest IDs. If a copied doc is removed in the destination, this will
    # still reference the source doc ID to this doc ID.
    idMap = {}
    # Default to the same ID if no mapping is found.
    getDestId = (id) -> idMap[id] ? id
    insertWithMap = (srcDoc) =>
      id = getDestId(srcDoc._id)
      return if Collections.hasDoc(dest, id)
      insert(srcDoc).then (insertId) -> idMap[srcDoc._id] = insertId

    @getCursor(src).forEach (doc) -> insertPromises.push insertWithMap(doc)
    if args.track
      if args.exclusive
        # Stop any existing copy.
        trackHandle = dest.trackHandle
        trackHandle.stop() if trackHandle
      dest.trackHandle = @observe src,
        added: insertWithMap
        changed: (newDoc, oldDoc) ->
          # If the document doesn't exist in the destination, don't track changes from the source.
          # Default to the same ID if no mapping is found.
          id = getDestId(newDoc._id)
          if dest.findOne(_id: id)
            dest.remove(id)
            insertWithMap(newDoc)
        removed: (oldDoc) ->
          id = getDestId(oldDoc._id)
          dest.remove id, (err, result) ->
            return unless result == 1
            delete idMap[id]
    Q.all(insertPromises).then -> dest

  # Used to ensure operations on collections are run in series. This should be used for creating new
  # MongoDB collections in asynchronous code to prevent interference.
  # @returns {Q.Promise} A promise which is resolved once collections are ready to be created.
  ready: (callback) ->
    @_queue ?= new DeferredQueue()
    @_queue.add(callback)

####################################################################################################
# DOCS
####################################################################################################

  moveDoc: (id, sourceCollection, destCollection) ->
    order = sourceCollection.findOne(_id: id)
    unless order
      throw new Error('Could not find doc with id ' + id + ' in collection ' + sourceCollection)
    destCollection.insert order, (err, result) ->
      if err
        throw new Error('Failed to insert into destination collection when moving')
      else
        sourceCollection.remove id, (err2, result2) ->
          if err2
            throw new Error('Failed to remove from source collection when moving')

  duplicateDoc: (docOrId, collection) ->
    df = Q.defer()
    doc = if Types.isObject(docOrId) then docOrId else collection.findOne(_id: docOrId)
    delete doc._id
    collection.insert doc, (err, result) -> if err then df.reject(err) else df.resolve(result)
    df.promise

  insertAll: (docs, collection) -> _.each docs, (doc) -> collection.insert(doc)

  removeAllDocs: (collection) ->
    # Non-reactive to ensure this command doesn't re-run when the collection changes.
    docs = Tracker.nonreactive -> collection.find().fetch()
    _.each docs, (doc) -> collection.remove(doc._id)

  # @param {Object} doc
  # @param {Object} modifier - A MongoDB modifier object.
  # @returns {Object} A copy of the given doc with the given modifier updates applied.
  simulateModifierUpdate: (doc, modifier) ->
    # TODO(aramk) If non-modifier properties are passed, this can result in them being merged at
    # times, though it should be throwing an error in mongo.
    if Object.keys(modifier).length > 1 && !modifier.$set? && !modifier.$unset?
      throw new Error('Unexpected keys in modifier.')
    tmpCollection = @createTemporary()
    doc = Setter.clone(doc)
    # This is synchronous since it's a local collection.
    insertedId = tmpCollection.insert(doc)
    tmpCollection.update(insertedId, modifier)
    tmpCollection.findOne(_id: insertedId)

  # @param {String|Meteor.Collection|Cursor} arg
  # @param {Object} selector
  # @param {Object} modifier
  # @param {Function} [callback]
  upsert: (arg, selector, modifier, callback) ->
    collection = @get(arg)
    unless collection
      throw new Error('No collection provided')
    doc = collection.findOne(selector)
    if doc
      collection.update(doc._id, modifier, callback)
    else
      doc = @simulateModifierUpdate({}, modifier)
      collection.insert(doc, callback)

  # @param {Meteor.Collection|Cursor|Array} docs
  # @param {Array.<Strings>} ids
  # @param {Object} [options]
  # @param {Boolean} [options.returnMap=false] - Whether to return a map of filtered IDs to
  #     documents instead of an array.
  # @returns {Array.<Object>|Object.<String, Object>} The given documents which match the given IDs.
  # This is typically more efficient than calling <code>find({_id: {$in: ids}})</code> for a large
  # number of ids.
  filterByIds: (docs, ids, options) ->
    docs = @getItems(docs)
    idMap = {}
    _.each ids, (id) -> idMap[id] = true
    docs = _.filter docs, (doc) ->
      exists = idMap[doc._id]?
      if options?.returnMap then idMap[doc._id] = doc
      exists
    if options?.returnMap then idMap else docs

  # @param {String|Meteor.Collection|Cursor} arg
  # @param {String} id - A document ID.
  # @returns {Boolean} Whether the given document ID exists in the given collection.
  hasDoc: (arg, id) ->
    unless id? then throw new Error('No document ID provided')
    collection = @get(arg)
    unless collection then throw new Error('No collection provided')
    collection._collection?._docs?.has(id) ? collection.findOne(_id: id)? ? false

  # @param {String|Meteor.Collection|Cursor} arg
  # @param {String} id - A document ID.
  # @param {Object} [options.clone=true] - Whether to clone the document (default). If false,
  #     the document object will be accessed directly from the IdMap if possible. This results in
  #     higher performance at the risk of exposing the mutable document.
  # @returns {Object} The document exists in the given collection.
  getDoc: (arg, id, options) ->
    unless id? then throw new Error('No document ID provided')
    collection = @get(arg)
    unless collection then throw new Error('No collection provided')
    if options?.clone == false
      collection._collection?._docs?.get(id)
    else
      collection.findOne(_id: id)

  getDocChanges: (oldDoc, newDoc) ->
    oldDoc = Objects.flattenProperties(oldDoc)
    newDoc = Objects.flattenProperties(newDoc)
    changes = {}
    _.each newDoc, (value, key) ->
      oldValue = oldDoc[key]
      if !oldValue? or value != oldValue
        # Change null values to undefined to mark the field as removed.
        if value == null then value = undefined
        changes[key] = value
    _.each oldDoc, (value, key) -> if !newDoc[key]? then changes[key] = undefined
    changes

####################################################################################################
# VALIDATION
####################################################################################################

  # Adds a validation method for the given colleciton. NOTE: Use allow() and deny() rules on
  # collections where possible to remain consistent with the Meteor API.
  # @param {Meteor.Collection} collection
  # @param {Function} validate - A validation method which returns a string on failure or throws
  #      an exception, which causes validation to fail and prevents insert() or update() on the
  #      collection from completing.
  addValidation: (collection, validate) ->
    collection.before.insert (userId, doc, options) =>
      return if options?.validate == false
      context = {userId: userId, options: options}
      @_handleValidationResult -> validate.call context, doc
    collection.before.update (userId, doc, fieldNames, modifier, options) =>
      return if options?.validate == false
      doc = @simulateModifierUpdate(doc, modifier)
      context =
        userId: userId
        fieldNames: fieldNames
        modifier: modifier
        options: options
      @_handleValidationResult -> validate.call context, doc

  _handleValidationResult: (callback) ->
    try
      result = callback()
      # TODO(aramk) The deferred won't run in time since hooks are not asynchronous yet, so it won't
      # prevent the collection methods from being called.
      # https://github.com/matb33/meteor-collection-hooks/issues/71
      handleResult = (invalidReason) -> throw invalidReason if invalidReason?
      if result?.then?
        result.then(handleResult, handleResult)
      else
        handleResult(result)
    catch err
      throw @_wrapMeteorError(err)

  # Returns a Meteor.Error. If `error` is not a Meteor.Error it is wrapped in one.
  _wrapMeteorError: (error) ->
    if error instanceof Meteor.Error
      error
    else if error instanceof Error
      wrapped = new Meteor.Error(500, error.message)
      wrapped.stack = error.stack
      wrapped
    else
      new Meteor.Error(500, error)

  # Simulates the given operation on the given collection. Throws errors on failure or true on
  # success.
  # TODO(aramk) This is more complex than currently required. WIP.
  # validateOperation: (collection, doc, operation, userId) ->
  #   unless _.contains ['insert', 'update', 'remove'], operation
  #     throw new Error('Invalid operation: ' + operation)
  #   if userId == undefined then userId = Meteor.userId()
  #   method = collection['_validated' + String.toTitleCase(operation)]
  #   unless method
  #     throw new Error('No method found for collection ' + @getName(collection) +
  #         ' and operation "' + operation + '"')
  #   # Calls the operation on the collection after removing the underlying collection to prevent
  #   # any side-effects, allowing any validation logic to be executed.
  #   origMethod = collection._collection[operation]
  #   collection._collection[operation] = ->

####################################################################################################
# SANITIZATION
####################################################################################################

  # @param {Meteor.Collection} collection
  # @param {Function} sanitize - A sanitization method which is passed a document before insertions
  #      or updates occur for the given collection. If a MongoDB modifier is returned, it is applied
  #      to the document before the operation takes place, allowing for any final changes.
  addSanitization: (collection, sanitize) ->
    collection.before.insert (userId, doc) =>
      context = {userId: userId}
      modifier = sanitize.call(context, doc)
      if modifier
        # TODO(aramk) Apply the change directly on the doc for better performance.
        updatedDoc = @simulateModifierUpdate(doc, modifier)
        Setter.merge(doc, updatedDoc)

    collection.before.update (userId, doc, fieldNames, modifier) ->
      updatedDoc = Collections.simulateModifierUpdate(doc, modifier)
      context = {userId: userId}
      # sanitizedDoc = Setter.clone(updatedDoc)
      sanitizeModifier = sanitize.call(context, updatedDoc)
      return unless sanitizeModifier
      # docDiff = Objects.diff(updatedDoc, sanitizedDoc)
      Setter.merge(modifier, sanitizeModifier)
      # Ensure no fields exist in $unset from $set.
      $unset = modifier.$unset
      if $unset
        _.each modifier.$set, (value, key) ->
          delete $unset[key]

####################################################################################################
# SCHEMAS
####################################################################################################

  getField: (arg, fieldId) ->
    schema = @getSchema(arg)
    unless schema
      throw new Error('Count not determine schema from: ' + arg)
    schema.schema(fieldId)

  # Traverse the given schema and call the given callback with the field schema and ID.
  forEachFieldSchema: (arg, callback) ->
    schema = Collections.getSchema(arg)
    unless schema
      throw new Error('Count not determine schema from: ' + arg)
    fieldIds = schema._schemaKeys
    for fieldId in fieldIds
      fieldSchema = schema.schema(fieldId)
      if fieldSchema?
        callback(fieldSchema, fieldId)

  getFields: (arg) ->
    fields = {}
    @forEachFieldSchema Collections.getSchema(arg), (field, fieldId) ->
      fields[fieldId] = field
    fields


