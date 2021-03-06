_ = require 'lodash'

mutations = require './mutations.coffee'
constants = require './constants.coffee'
utils = require './utils.coffee'
errors = require './errors.coffee'
Cursor = require './cursor.coffee'
Register = require './register.coffee'
Logger = require './logger.coffee'
EventEmitter = require './eventEmitter.coffee'
Path = require './path.coffee'

Modes = require './modes.coffee'
MODES = Modes.modes

###
a Session represents a session with a vimflowy document
It holds a Cursor, a Document object, and a Settings object
It exposes methods for manipulation of the document, and movement of the cursor

Currently, the separation between the Session and Document classes is not very good.  (see document.coffee)
Ideally, session shouldn't do much more than handle cursors and history
###

class Session extends EventEmitter
  constructor: (doc, options = {}) ->
    super

    @document = doc

    @bindings = options.bindings
    @settings = options.settings
    # session needs to know div for page scrolling, getting visible rows
    @mainDiv = options.mainDiv
    @messageDiv = options.messageDiv
    @menuDiv = options.menuDiv

    @register = new Register @

    # TODO: if we ever support multi-user case, ensure last view root is valid
    @viewRoot = Path.loadFromAncestry (do @document.store.getLastViewRoot || [])
    if not (@document.hasChildren @document.root.row)
      @document.load constants.empty_data

    if @viewRoot.is @document.root
      path = (@document.getChildren @viewRoot)[0]
    else
      path = @viewRoot
    @cursor = new Cursor @, path, 0

    do @reset_history
    do @reset_jump_history

    @setMode MODES.NORMAL
    return @

  exit: () ->
    @emit "exit"

  #################
  # modes related
  #################

  setMode: (newmode) ->
    if newmode == @mode
      return

    oldmode = @mode
    if oldmode
      (Modes.getMode oldmode).exit @, newmode

    @mode = newmode
    (Modes.getMode @mode).enter @, oldmode

    @emit 'modeChange', oldmode, newmode

  toggleBindingsDiv: () ->
    @emit 'toggleBindingsDiv'

  #################
  # show message
  #################

  showMessage: (message, options = {}) ->
    options.time ?= 5000
    Logger.logger.info "Showing message: #{message}"
    if @messageDiv
      clearTimeout @messageDivTimeout

      @messageDiv.text(message)
      if options.text_class
        @messageDiv.addClass("text-#{options.text_class}")

      @messageDivTimeout = setTimeout (() =>
        @messageDiv.text('')
        @messageDiv.removeClass()
      ), options.time

  #################
  # import/export #
  #################

  parseJson: (content) ->
    try
      root = JSON.parse(content)
    catch
      @showMessage "The uploaded file is not valid JSON", {text_class: 'error'}
      return false
    verify = (node) ->
      if node.clone
        return true
      unless node.text || node.text == '' then return false
      if node.children
        for child in node.children
          unless verify child then return false
      return true
    unless verify root
      @showMessage "The uploaded file is not in a valid vimflowy format", {text_class: 'error'}
      return false
    return root

  parsePlaintext: (content) ->
    # Step 1: parse into (int, string) pairs of indentation amounts.
    lines = []
    for line in content.split "\n"
      if line.match /^\s*".*"$/ # Flag workflowy annotations as special cases
        lines.push
          indent: (line.match whitespace)[0].length
          line: line.replace /^\s*"(.*)"$/, "$1"
          annotation: true
        continue
      whitespace = /^\s*/
      # TODO: record whether COMPLETE and strikethrough line if so?
      lines.push
        indent: (line.match whitespace)[0].length
        line: (line.replace whitespace, "").replace /^(?:-\s*)?(?:\[COMPLETE\] )?/, ""
    while lines[lines.length-1].line == '' # Strip trailing blank line(s)
      lines = lines.splice(0, lines.length-1)

    # Step 2: convert a list of (int, string, annotation?) into a forest format
    parseAllChildren = (parentIndentation, lineNumber) ->
      children = []
      if lineNumber < lines.length and lines[lineNumber].annotation # Each node can have an annotation immediately follow it
        children.push
          text: lines[lineNumber].line
        lineNumber = lineNumber + 1
      while lineNumber < lines.length and lines[lineNumber].indent > parentIndentation # For [the first line of] each child
        child =
          text: lines[lineNumber].line
        result = parseAllChildren lines[lineNumber].indent, lineNumber + 1
        lineNumber = result.lineNumber
        if result.children?
          child.children = result.children
          child.collapsed = result.children.length > 0
        children.push child
      return { children: children, lineNumber: lineNumber}
    forest = (parseAllChildren -1, 0).children
    root =
      text: ""
      children: forest
      collapsed: (forest.length > 0)
    return root

  parseContent: (content, mimetype) ->
    if mimetype in ['application/json']
      return @parseJson content
    else if mimetype in ['text/plain', 'Text']
      return @parsePlaintext content
    else
      return null

  # TODO: make this use replace_empty = true?
  importContent: (content, mimetype) ->
    root = @parseContent content, mimetype
    if not root then return false
    path = @cursor.path
    if root.text == '' && root.children # Complete export, not one node
      @addBlocks path, 0, root.children
    else
      @addBlocks path, 0, [root]
    do @save
    @emit 'importFinished'
    return true

  exportContent: (mimetype) ->
    jsonContent = do @document.serialize
    if mimetype == 'application/json'
      delete jsonContent.viewRoot
      return JSON.stringify(jsonContent, undefined, 2)
    else if mimetype == 'text/plain'
      # Workflowy compatible plaintext export
      #   Ignores 'collapsed' and viewRoot
      indent = "  "
      exportLines = (node) ->
        if typeof(node) == 'string'
          return ["- #{node}"]
        lines = []
        lines.push "- #{node.text}"
        for child in node.children ? []
          if child.clone
            continue
          for line in exportLines child
            lines.push "#{indent}#{line}"
        return lines
      return (exportLines jsonContent).join "\n"
    else
      throw new errors.UnexpectedValue "mimetype", mimetype

  #################
  # MUTATIONS
  #################

  reset_history: () ->
    @mutations = [] # full mutation history
    @history = [{
      index: 0
    }]
    @historyIndex = 0 # index into indices

  save: () ->
    if @historyIndex != @history.length - 1
      # haven't acted, otherwise would've sliced
      return
    if @history[@historyIndex].index == @mutations.length
      # haven't acted, otherwise there would be more mutations
      return

    state = @history[@historyIndex]
    state.after = {
      cursor: do @cursor.clone
      viewRoot: @viewRoot
    }

    @historyIndex += 1
    @history.push {
      index: @mutations.length
    }

  restoreViewState: (state) ->
    @cursor.from state.cursor
    do @fixCursorForMode
    @changeView state.viewRoot

  undo: () ->
    if @historyIndex > 0
      oldState = @history[@historyIndex]
      @historyIndex -= 1
      newState = @history[@historyIndex]

      Logger.logger.debug "UNDOING ("
      for i in [(oldState.index-1)...(newState.index-1)]
        mutation = @mutations[i]
        Logger.logger.debug "  Undoing mutation #{mutation.constructor.name}(#{mutation.str()})"
        undo_mutations = mutation.rewind @
        for undo_mutation in undo_mutations
          Logger.logger.debug "  Undo mutation #{undo_mutation.constructor.name}(#{undo_mutation.str()})"
          undo_mutation.mutate @
          undo_mutation.moveCursor @cursor

      Logger.logger.debug ") END UNDO"
      @restoreViewState newState.before

  redo: () ->
    if @historyIndex < @history.length - 1
      oldState = @history[@historyIndex]
      @historyIndex += 1
      newState = @history[@historyIndex]

      Logger.logger.debug "REDOING ("
      for i in [oldState.index...newState.index]
        mutation = @mutations[i]
        Logger.logger.debug "  Redoing mutation #{mutation.constructor.name}(#{mutation.str()})"
        if not mutation.validate @
          # this should not happen, since the state should be the same as before
          throw new errors.GenericError "Failed to redo mutation: #{mutation.str()}"
        mutation.remutate @
        mutation.moveCursor @cursor
      Logger.logger.debug ") END REDO"
      @restoreViewState oldState.after

  do: (mutation) ->
    if not @history
      # NOTE: we let mutations through since some plugins may apply mutations on load
      # these mutations won't be undoable, which is desired
      Logger.logger.warn "Tried mutation #{mutation} before init!"
      mutation.mutate @
      return true

    if @historyIndex != @history.length - 1
      @history = @history.slice 0, (@historyIndex + 1)
      @mutations = @mutations.slice 0, @history[@historyIndex].index

    state = @history[@historyIndex]
    if @mutations.length == state.index
      state.before = {
        cursor: do @cursor.clone
        viewRoot: @viewRoot
      }

    Logger.logger.debug "Applying mutation #{mutation.constructor.name}(#{mutation.str()})"
    if not mutation.validate @
      return false
    mutation.mutate @
    mutation.moveCursor @cursor
    # TODO: do this elsewhere
    do @fixCursorForMode

    @mutations.push mutation
    return true

  fixCursorForMode: () ->
    if (Modes.getMode @mode).metadata.hotkey_type != Modes.INSERT_MODE_TYPE
      do @cursor.backIfNeeded

  ##################
  # viewability
  ##################

  # whether contents are currently viewable.  ASSUMES ROW IS WITHIN VIEWROOT
  viewable: (path) ->
    return (not @document.collapsed path.row) or (path.is @viewRoot)

  nextVisible: (path) ->
    if @viewable path
      children = @document.getChildren path
      if children.length > 0
        return children[0]
    if path.is @viewRoot
      return null
    while true
      nextsib = @document.getSiblingAfter path
      if nextsib?
        return nextsib
      path = path.parent
      if path.is @viewRoot
        return null

  # last thing visible nested within id
  lastVisible: (path = @viewRoot) ->
    if not @viewable path
      return path
    children = @document.getChildren path
    if children.length > 0
      return @lastVisible children[children.length - 1]
    return path

  prevVisible: (path) ->
    if path.is @viewRoot
      return null
    prevsib = @document.getSiblingBefore path
    if prevsib?
      return @lastVisible prevsib
    parent = path.parent
    if parent.is @viewRoot
      if parent.is @document.root
        return null
      else
        return @viewRoot
    return parent

  # finds oldest ancestor that is visible *besides viewRoot*
  # returns null if there is no visible ancestor (i.e. path is not under viewroot)
  oldestVisibleAncestor: (path) ->
    last = path
    while true
      cur = last.parent
      if cur.is @viewRoot
        return last
      if do cur.isRoot
        return null
      last = cur

  # finds closest ancestor that is visible
  # returns null if there is no visible ancestor (i.e. path is not under viewroot)
  youngestVisibleAncestor: (path) ->
    answer = path
    cur = path
    while true
      if cur.is @viewRoot
        return answer
      if do cur.isRoot
        return null
      if @document.collapsed cur.row
        answer = cur
      cur = cur.parent

  isVisible: (path) ->
    visibleAncestor = @youngestVisibleAncestor path
    (visibleAncestor != null) and (path.is visibleAncestor)

  ##################
  # View root
  ##################

  _changeViewRoot: (path) ->
    @viewRoot = path
    @document.store.setLastViewRoot do path.getAncestry

  reset_jump_history: () ->
    @jumpHistory = [{
      viewRoot: @viewRoot
      cursor_before: do @cursor.clone
    }]
    @jumpIndex = 0 # index into jump history

  addToJumpHistory: (jump_fn) ->
    jump = @jumpHistory[@jumpIndex]
    jump.cursor_after = do @cursor.clone

    @jumpHistory = @jumpHistory.slice 0, (@jumpIndex+1)

    do jump_fn

    @jumpHistory.push {
      viewRoot: @viewRoot
      cursor_before: do @cursor.clone
    }
    @jumpIndex += 1

  # try going to jump, return true if succeeds
  tryJump: (jump) ->
    if jump.viewRoot.row == @viewRoot.row
      return false # not moving, don't jump

    if not @document.isAttached jump.viewRoot.row
      return false # invalid location

    children = @document.getChildren jump.viewRoot

    @_changeViewRoot jump.viewRoot
    if children.length
      @cursor.setPath children[0]
    else
      @cursor.setPath jump.viewRoot

    if @document.isAttached jump.cursor_after.row
      # if the row is attached and under the view root, switch to it
      cursor_path = @youngestVisibleAncestor jump.cursor_after.path
      if cursor_path != null
        @cursor.setPath cursor_path
    return true

  jumpPrevious: () ->
    jumpIndex = @jumpIndex

    jump = @jumpHistory[jumpIndex]
    jump.cursor_after = do @cursor.clone

    while true
      if jumpIndex == 0
        return false
      jumpIndex -= 1
      oldjump = @jumpHistory[jumpIndex]
      if @tryJump oldjump
        @jumpIndex = jumpIndex
        return true

  jumpNext: () ->
    jumpIndex = @jumpIndex

    jump = @jumpHistory[jumpIndex]
    jump.cursor_after = do @cursor.clone

    while true
      if jumpIndex == @jumpHistory.length - 1
        return false
      jumpIndex += 1
      newjump = @jumpHistory[jumpIndex]
      if @tryJump newjump
        @jumpIndex = jumpIndex
        return true

  # try to change the view root to row
  # fails if there is no child
  # records in jump history
  changeView: (path) ->
    if path.row == @viewRoot.row
      return # not moving, do nothing
    @addToJumpHistory () =>
      @_changeViewRoot path

  # try to zoom into newroot, updating the cursor
  zoomInto: (newroot) ->
    @changeView newroot
    newrow = @youngestVisibleAncestor @cursor.path
    if newrow == null # not visible, need to reset cursor
      newrow = newroot
    @cursor.setPath newrow

  zoomOut: () ->
    if @viewRoot.row != @document.root.row
      parent = @viewRoot.parent
      @zoomInto parent

  zoomIn: () ->
    if @cursor.path.is @viewRoot
      return false
    newroot = @oldestVisibleAncestor @cursor.path
    if @zoomInto newroot
      return true
    return false

  zoomDown: () ->
    sib = @document.getSiblingAfter @viewRoot
    if sib == null
      @showMessage "No next sibling to zoom down to", {text_class: 'error'}
      return
    @zoomInto sib

  zoomUp: () ->
    sib = @document.getSiblingBefore @viewRoot
    if sib == null
      @showMessage "No previous sibling to zoom up to", {text_class: 'error'}
      return
    @zoomInto sib

  ##################
  # Text
  ##################

  curLine: () ->
    return @document.getLine @cursor.row

  curText: () ->
    return @document.getText @cursor.row

  curLineLength: () ->
    return @document.getLength @cursor.row

  addChars: (row, col, chars) ->
    @do new mutations.AddChars row, col, chars

  addCharsAtCursor: (chars) ->
    @addChars @cursor.row, @cursor.col, chars

  addCharsAfterCursor: (chars) ->
    col = @cursor.col
    if col < (@document.getLength @cursor.row)
      col += 1
    @addChars @cursor.row, col, chars

  delChars: (path, col, nchars, options = {}) ->
    n = @document.getLength path.row
    deleted = []
    if (n > 0) and (nchars > 0) and (col < n)
      mutation = new mutations.DelChars path.row, col, nchars
      @do mutation
      deleted = mutation.deletedChars
      if options.yank
        @register.saveChars deleted
    return deleted

  delCharsBeforeCursor: (nchars, options) ->
    nchars = Math.min(@cursor.col, nchars)
    return @delChars @cursor.path, (@cursor.col-nchars), nchars, options

  delCharsAfterCursor: (nchars, options) ->
    return @delChars @cursor.path, @cursor.col, nchars, options

  changeChars: (row, col, nchars, change_fn) ->
    mutation = new mutations.ChangeChars row, col, nchars, change_fn
    @do mutation
    return mutation.ncharsDeleted

  replaceCharsAfterCursor: (char, nchars) ->
    ndeleted = @changeChars @cursor.row, @cursor.col, nchars, ((chars) ->
      return chars.map ((char_obj) ->
        new_obj = _.clone char_obj
        new_obj.char = char
        return new_obj
      )
    )
    @cursor.setCol (@cursor.col + ndeleted - 1)

  clearRowAtCursor: (options) ->
    if options.yank
      # yank as a row, not chars
      do @yankRowAtCursor
    @delChars @cursor.path, 0, (do @curLineLength)

  yankChars: (path, col, nchars) ->
    line = @document.getLine path.row
    if line.length > 0
      @register.saveChars line.slice(col, col + nchars)

  # options:
  #   - includeEnd says whether to also delete cursor2 location
  yankBetween: (cursor1, cursor2, options = {}) ->
    if not (cursor2.path.is cursor1.path)
      Logger.logger.warn "Not yet implemented"
      return

    if cursor2.col < cursor1.col
      [cursor1, cursor2] = [cursor2, cursor1]

    offset = if options.includeEnd then 1 else 0
    @yankChars cursor1.path, cursor1.col, (cursor2.col - cursor1.col + offset)

  yankRowAtCursor: () ->
    serialized_row = @document.serializeRow @cursor.row
    @register.saveSerializedRows [serialized_row]

  # options:
  #   - includeEnd says whether to also delete cursor2 location
  deleteBetween: (cursor1, cursor2, options = {}) ->
    if not (cursor2.path.is cursor1.path)
      Logger.logger.warn "Not yet implemented"
      return

    if cursor2.col < cursor1.col
      [cursor1, cursor2] = [cursor2, cursor1]
    offset = if options.includeEnd then 1 else 0
    @delChars cursor1.path, cursor1.col, (cursor2.col - cursor1.col + offset), options

  # TODO: fix a bunch of these to use rows (they're still actually paths)

  # toggling text properties
  # if new_value is null, should be inferred based on old values
  toggleProperty: (property, new_value, row, col, n) ->
    @changeChars row, col, n, ((deleted) ->
      if new_value == null
        all_were_true = _.every deleted.map ((obj) -> return obj[property])
        new_value = not all_were_true

      return deleted.map ((char_obj) ->
        new_obj = _.clone char_obj
        new_obj[property] = new_value
        return new_obj
      )
    )

  toggleRowsProperty: (property, rows) ->
    all_were_true = _.every rows.map ((row) =>
      _.every (@document.getLine row).map ((obj) -> return obj[property])
    )
    new_value = not all_were_true
    for row in rows
      @toggleProperty property, new_value, row, 0, (@document.getLength row)

  toggleRowProperty: (property, row = @cursor.row) ->
    @toggleProperty property, null, row, 0, (@document.getLength row)

  toggleRowPropertyBetween: (property, cursor1, cursor2, options) ->
    if not (cursor2.path.is cursor1.path)
      Logger.logger.warn "Not yet implemented"
      return

    if cursor2.col < cursor1.col
      [cursor1, cursor2] = [cursor2, cursor1]

    offset = if options.includeEnd then 1 else 0
    @toggleProperty property, null, cursor1.row, cursor1.col, (cursor2.col - cursor1.col + offset)

  newLineBelow: (options = {}) ->
    options.setCursor = 'first'

    if @cursor.path.is @viewRoot
      if not (@document.hasChildren @cursor.row)
        if not @document.collapsed @cursor.row
          @toggleBlockCollapsed @cursor.row

      @addBlocks @cursor.path, 0, [''], options
    else if (not @document.collapsed @cursor.row) and @document.hasChildren @cursor.row
      @addBlocks @cursor.path, 0, [''], options
    else
      parent = @cursor.path.parent
      index = @document.indexOf @cursor.path
      @addBlocks parent, (index+1), [''], options

  newLineAbove: () ->
    if @cursor.path.is @viewRoot
      return
    parent = @cursor.path.parent
    index = @document.indexOf @cursor.path
    @addBlocks parent, index, [''], {setCursor: 'first'}

  # behavior of "enter", splitting a line
  # If enter is not at the end:
  #     insert a new node before with the first half of the content
  #     note that this will always preserve child-parent relationships
  # If enter is at the end:
  #     insert a new node after
  #     if the node has children, this is the new first child
  newLineAtCursor: () ->
    if @cursor.col == @document.getLength @cursor.row
      @newLineBelow {cursorOptions: {keepProperties: true}}
    else
      mutation = new mutations.DelChars @cursor.row, 0, @cursor.col
      @do mutation
      path = @cursor.path

      do @newLineAbove
      # cursor now is at inserted path, add the characters
      @addCharsAfterCursor mutation.deletedChars
      # restore cursor
      @cursor.set path, 0, {keepProperties: true}

  # can only join if either:
  # - first is previous sibling of second, AND has no children
  # - second is first child of first, AND has no children
  joinRows: (first, second, options = {}) ->
    addDelimiter = false
    firstLine = @document.getLine first.row
    secondLine = @document.getLine second.row
    if options.delimiter
      if firstLine.length and secondLine.length
        if firstLine[firstLine.length - 1].char != options.delimiter
          if secondLine[0].char != options.delimiter
            addDelimiter = true

    if not (@document.hasChildren second.row)
      @cursor.set first, -1
      @delBlock second, {noNew: true, noSave: true}
      if addDelimiter
        mutation = new mutations.AddChars first.row, firstLine.length, [{ char: options.delimiter }]
        @do mutation
      mutation = new mutations.AddChars first.row, (firstLine.length + addDelimiter), secondLine
      @do mutation
      @cursor.set first, firstLine.length
      return true

    if @document.hasChildren first.row
      @showMessage "Cannot join when both rows have children", {text_class: 'error'}
      return false

    if second.parent.row != first.parent.row
      @showMessage "Cannot join with non sibling/child", {text_class: 'error'}
      return false

    @cursor.set second, 0
    @delBlock first, {noNew: true, noSave: true}
    if addDelimiter
      mutation = new mutations.AddChars second.row, 0, [{ char: options.delimiter }]
      @do mutation
    mutation = new mutations.AddChars second.row, 0, firstLine
    @do mutation

    if addDelimiter
      do @cursor.left

    return true

  joinAtCursor: () ->
    path = @cursor.path
    sib = @nextVisible path
    if sib != null
      @joinRows path, sib, {delimiter: ' '}

  # implements proper "backspace" behavior
  deleteAtCursor: () ->
    if @cursor.col > 0
      @delCharsBeforeCursor 1, {cursor: {pastEnd: true}}
      return true

    path = @cursor.path
    sib = @prevVisible path
    if sib == null
      return false

    if @joinRows sib, path
      return true

    return false

  delBlock: (path, options) ->
    @delBlocks path.parent.row, (@document.indexOf path), 1, options

  delBlocks: (parent, index, nrows, options = {}) ->
    mutation = new mutations.DetachBlocks parent, index, nrows, options
    @do mutation
    unless options.noSave
      @register.saveClonedRows mutation.deleted
    if not (@isVisible @cursor.path)
      # view root got deleted
      do @zoomOut

  delBlocksAtCursor: (nrows, options = {}) ->
    parent = @cursor.path.parent
    index = @document.indexOf @cursor.path
    @delBlocks parent.row, index, nrows, options

  addBlocks: (parent, index = -1, serialized_rows, options = {}) ->
    mutation = new mutations.AddBlocks parent, index, serialized_rows, options
    @do mutation
    if options.setCursor == 'first'
      @cursor.set mutation.added_rows[0], 0, options.cursorOptions
    else if options.setCursor == 'last'
      @cursor.set mutation.added_rows[mutation.added_rows.length - 1], 0, options.cursorOptions

  yankBlocks: (path, nrows) ->
    siblings = @document.getSiblingRange path, 0, (nrows-1)
    siblings = siblings.filter ((x) -> return x != null)
    serialized = siblings.map ((x) => return @document.serialize x.row)
    @register.saveSerializedRows serialized

  yankBlocksAtCursor: (nrows) ->
    @yankBlocks @cursor.path, nrows

  yankBlocksClone: (row, nrows) ->
    siblings = @document.getSiblingRange row, 0, (nrows-1)
    siblings = siblings.filter ((x) -> return x != null)
    @register.saveClonedRows (siblings.map (sibling) -> sibling.row)

  yankBlocksCloneAtCursor: (nrows) ->
    @yankBlocksClone @cursor.path, nrows

  attachBlocks: (parent, ids, index = -1, options = {}) ->
    mutation = new mutations.AttachBlocks parent.row, ids, index, options
    will_work = mutation.validate @
    @do mutation

    # TODO: do this more elegantly
    if will_work
      if options.setCursor == 'first'
        @cursor.set (@document.findChild parent, ids[0]), 0
      else if @options.setCursor == 'last'
        @cursor.set (@document.findChild parent, ids[ids.length-1]), 0

  moveBlock: (path, parent_path, index = -1) ->
    @do new mutations.MoveBlock path, parent_path, index

  indentBlocks: (row, numblocks = 1) ->
    if row.is @viewRoot
      @showMessage "Cannot indent view root", {text_class: 'error'}
      return
    newparent = @document.getSiblingBefore row
    unless newparent?
      @showMessage "Cannot indent without higher sibling", {text_class: 'error'}
      return null # cannot indent

    if @document.collapsed newparent.row
      @toggleBlockCollapsed newparent.row

    siblings = (@document.getSiblingRange row, 0, (numblocks-1)).filter ((sib) -> sib != null)
    for sib in siblings
      @moveBlock sib, newparent, -1
    return newparent

  unindentBlocks: (row, numblocks = 1) ->
    if row.is @viewRoot
      @showMessage "Cannot unindent view root", {text_class: 'error'}
      return
    parent = row.parent
    if parent.row == @viewRoot.row
      @showMessage "Cannot unindent past root", {text_class: 'error'}
      return null

    siblings = (@document.getSiblingRange row, 0, (numblocks-1)).filter ((sib) -> sib != null)

    newparent = parent.parent
    pp_i = @document.indexOf parent

    for sib in siblings
      pp_i += 1
      @moveBlock sib, newparent, pp_i
    return newparent

  indent: (path = @cursor.path) ->
    if path.is @viewRoot
      @showMessage "Cannot indent view root", {text_class: 'error'}
      return
    if @document.collapsed path.row
      return @indentBlocks path

    sib = @document.getSiblingBefore path

    newparent = @indentBlocks path
    unless newparent?
      return
    for child in (@document.getChildren path).slice()
      @moveBlock child, sib, -1

  unindent: (path = @cursor.path) ->
    if path.is @viewRoot
      @showMessage "Cannot unindent view root", {text_class: 'error'}
      return
    if @document.collapsed path.row
      return @unindentBlocks path

    if @document.hasChildren path.row
      @showMessage "Cannot unindent line with children", {text_class: 'error'}
      return

    parent = path.parent
    p_i = @document.indexOf path

    newparent = @unindentBlocks path
    unless newparent?
      return

    p_children = @document.getChildren parent
    for child in p_children.slice(p_i)
      @moveBlock child, path, -1

  swapDown: (path = @cursor.path) ->
    next = @nextVisible (@lastVisible path)
    unless next?
      return

    if (@document.hasChildren next.row) and (not @document.collapsed next.row)
      # make it the first child
      @moveBlock path, next, 0
    else
      # make it the next sibling
      parent = next.parent
      p_i = @document.indexOf next
      @moveBlock path, parent, (p_i+1)

  swapUp: (path = @cursor.path) ->
    prev = @prevVisible path
    unless prev?
      return

    # make it the previous sibling
    parent = prev.parent
    p_i = @document.indexOf prev
    @moveBlock path, parent, p_i

  toggleCurBlockCollapsed: () ->
    @toggleBlockCollapsed @cursor.row

  toggleBlockCollapsed: (row) ->
    @do new mutations.ToggleBlock row

  pasteBefore: () ->
    @register.paste {before: true}

  pasteAfter: () ->
    @register.paste {}

  # given an anchor and cursor, figures out the right blocks to be deleting
  # returns a parent, minindex, and maxindex
  getVisualLineSelections: () ->
    [common, ancestors1, ancestors2] = @document.getCommonAncestor @cursor.path, @anchor.path
    if ancestors1.length == 0
      # anchor is underneath cursor
      parent = common.parent
      index = @document.indexOf @cursor.path
      return [parent, index, index]
    else if ancestors2.length == 0
      # cursor is underneath anchor
      parent = common.parent
      index = @document.indexOf @anchor.path
      return [parent, index, index]
    else
      index1 = @document.indexOf (ancestors1[0] ? @cursor.path)
      index2 = @document.indexOf (ancestors2[0] ? @anchor.path)
      if index2 < index1
        [index1, index2] = [index2, index1]
      return [common, index1, index2]

  ###################
  # scrolling
  ###################

  scroll: (npages) ->
    @emit 'scroll', npages
    # TODO:  find out height per line, figure out number of lines to move down, scroll down corresponding height
    line_height = $('.node-text').height() or 21
    errors.assert (line_height > 0)
    page_height = do $(document).height
    height = npages * page_height

    numlines = Math.round(height / line_height)
    numlines = Math.max(Math.min(numlines, 1000), -1000) # guard against craziness

    if numlines > 0
      for i in [1..numlines]
        do @cursor.down
    else
      for i in [-1..numlines]
        do @cursor.up

    @scrollMain (line_height * numlines)

  scrollMain: (amount) ->
    # # animate.  seems to not actually be great though
    # @mainDiv.stop().animate({
    #     scrollTop: @mainDiv[0].scrollTop + amount
    #  }, 50)
    @mainDiv.scrollTop(@mainDiv.scrollTop() + amount)

  scrollIntoView: (el) ->
    elemTop = el.getBoundingClientRect().top
    elemBottom = el.getBoundingClientRect().bottom

    margin = 50
    top_margin = margin
    bottom_margin = margin + $('#bottom-bar').height()

    if elemTop < top_margin
      # scroll up
      @scrollMain (elemTop - top_margin)
    else if elemBottom > window.innerHeight - bottom_margin
      # scroll down
      @scrollMain (elemBottom - window.innerHeight + bottom_margin)

  getVisiblePaths: () ->
    paths = []
    for bullet in $.makeArray($('.bullet'))
      if not (utils.isScrolledIntoView $(bullet), @mainDiv)
        continue
      if $(bullet).hasClass 'fa-clone'
        continue
      # NOTE: can't use $(x).data
      # http://stackoverflow.com/questions/25876274/jquery-data-not-working
      ancestry = $(bullet).attr('data-ancestry')
      if not ancestry # as far as i know, this only happens because of menu mode
        continue
      path = Path.loadFromAncestry JSON.parse ancestry
      paths.push path
    return paths

# exports
module.exports = Session
