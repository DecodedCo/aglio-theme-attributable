markdownIt  = require 'markdown-it'
hljs        = require 'highlight.js'
jade        = require 'jade'
less        = require 'less'
moment      = require 'moment'
path        = require 'path'
querystring = require 'querystring'
crypto      = require 'crypto'
fs          = require 'fs'
ROOT        = path.dirname(__dirname)
cache       = {}
exports     = {}
slugify     = null

errMsg = (message, err) ->
  err.message = "#{message}: #{err.message}"
  err

sha1 = (value) ->
  crypto.createHash('sha1')
        .update(value.toString())
        .digest('hex')

highlight = (code, lang, subset) ->
  (->
    switch lang
      when 'no-highlight' then code
      when null           then hljs.highlightAuto(code, subset).value;
      when ''             then hljs.highlightAuto(code, subset).value;
      else                     hljs.highlight(lang, code).value;
  )().trim()

slug = (cache, value, unique) ->
  cache  = {}    if cache  is null
  value  = ''    if value  is null
  unique = false if unique is null

  sluggified = value.toLowerCase()
                    .replace(/[ \t\n\\<>"'=:\/]/g, '-')
                    .replace(/-+/g, '-')
                    .replace(/^-/, '')

  if unique
    while cache[sluggified]
      sluggified = if sluggified.match(/\d+$/)
                     sluggified.replace /\d+$/, (value) ->
                      parseInt(value) + 1
                   else
                     sluggified + '-1'

  cache[sluggified] = true
  sluggified

getCached = (key, compiledPath, sources, load, done) ->
  return done(null)             if (process.env.NOCACHE)
  return done(null, cache[key]) if (cache[key])

  try
    if fs.existsSync(compiledPath)
      compiledStats = fs.statSync(compiledPath)

      for source in sources
        sourceStats = fs.statSync(source)

        done(null) if sourceStats.mtime > compiledStats.mtime

      try
        load compiledPath, (err, item) ->
          done(errMsg('Error loading cached resource', err)) if err

          cache[key] = item

          done(null, cache[key])
      catch _error
        done errMsg('Error loading cached resource', _error)
    else
      done(null)
  catch _error
    done _error

getCss = (variables, styles, verbose, done) ->
  key = "css-#{variables}-#{styles}"

  return done(null, cache[key]) if (cache[key])

  compiledPath        = path.join(ROOT, 'cache', "#{sha1(key)}.css")
  defaultVariablePath = path.join(ROOT, 'styles', 'variables-default.less')
  variablePaths       = [defaultVariablePath];
  sources             = [defaultVariablePath]

  variables           = [variables] if !Array.isArray(variables)
  styles              = [styles]    if !Array.isArray(styles)

  for variable in variables
    if variable != 'default'
      customPath = path.join(ROOT, 'styles', "variables-#{variable}.less")

      done new Error("#{variable} does not exist!") if !fs.existsSync(customPath) and !fs.existsSync(variable)

      variablePaths.push(customPath)
      sources.push(customPath)

  stylePaths = [];

  for style in styles
    customPath = path.join(ROOT, 'styles', "layout-#{style}.less")

    done new Error("#{style} does not exist!") if !fs.existsSync(customPath) and !fs.existsSync(style)

    stylePaths.push(customPath)
    sources.push(customPath)

  load = (filename, loadDone) ->
    fs.readFile(filename, 'utf-8', loadDone)

  if verbose
    console.log "Using variables #{variablePaths}"
    console.log "Using styles #{stylePaths}"
    console.log "Checking cache #{compiledPath}"

  getCached key, compiledPath, sources, load, (err, css) ->
    return done(err)       if err
    return done(null, css) if css

    console.log('Not cached or out of date. Generating CSS...') if verbose

    tmp = ''

    for customPath in variablePaths
      tmp += "@import \"#{customPath}\";\n"

    for customPath in stylePaths
      tmp += "@import \"#{customPath}\";\n"

    lessErrorHandler = (err, result) ->
      return done msgErr('Error processing LESS -> CSS', err) if err

      try
        css = result.css
        fs.writeFileSync(compiledPath, css, 'utf-8')
      catch _error
        return done errMsg('Error writing cached CSS to file', _error)

      cache[key] = css

      done null, cache[key]

    less.render tmp, { compress: true }, lessErrorHandler

compileTemplate = (filename, options) ->
  "var jade = require('jade/runtime');\n#{jade.compileFileClient(filename, options)}\nmodule.exports = compiledFunc;"

getTemplate = (name, verbose, done) ->
  key = "template-#{name}"

  return done(null, cache[key]) if cache[key]

  compiledPath = path.join(ROOT, 'cache', "#{sha1(key)}.js")

  load = (filename, loadDone) ->
    try
      loaded = require(filename)
    catch _error
      loadDone errMsg('Unable to load template', _error)

    loadDone null, require(filename)

  if verbose
    console.log "Using template #{name}"
    console.log "Checking cache #{compiledPath}"

  getCached key, compiledPath, [name], load, (err, template) ->
    return done(err) if err

    if template
      console.log('Cached version loaded') if verbose
      done(null, template)

    console.log('Not cached or out of date. Generating template JS...') if verbose

    compileOptions =
      filename:      name
      name:          'compiledFunc'
      self:          true
      compileDebug:  false

    try
      compiled = compileTemplate(name, compileOptions)
    catch _error
      done errMsg('Error compiling template', _error)

    if compiled.indexOf('self.') == -1
      compileOptions.self = false

      try
        compiled = compileTemplate(name, compileOptions)
      catch _error
        done errMsg('Error compiling template', _error)

    try
      fs.writeFileSync(compiledPath, compiled, 'utf-8')
    catch _error
      done errMsg('Error writing cached template file', _error)

    cache[key] = require(compiledPath)

    done null, cache[key]

modifyUriTemplate = (templateUri, parameters) ->

  parameterValidator = (b) ->
    parameters.indexOf(querystring.unescape(b.replace(/^\*|\*$/, ''))) != -1

  parameters = parameters.map (param) -> param.name

  parameterBlocks = []
  lastIndex       = 0
  index           = 0

  while (index = templateUri.indexOf("{", index)) != -1

    parameterBlocks.push templateUri.substring(lastIndex, index)
    block = {}
    closeIndex = templateUri.indexOf("}", index)

    block.querySet    = templateUri.indexOf("{?", index) == index
    block.formSet     = templateUri.indexOf("{&", index) == index
    block.reservedSet = templateUri.indexOf("{+", index) == index
    lastIndex         = closeIndex + 1

    index++
    index++ if block.querySet

    parameterSet     = templateUri.substring(index, closeIndex)
    block.parameters = parameterSet.split(",")
                                   .filter(parameterValidator)

    parameterBlocks.push(block) if (block.parameters.length)

  parameterBlocks.push templateUri.substring(lastIndex, templateUri.length)

  reduceUri = (uri, v) ->
    if typeof v == "string"
      uri.push(v);
    else
      segment = ["{"]
      segment.push("?") if v.querySet
      segment.push("&") if v.formSet
      segment.push("+") if v.reservedSet

      segment.push(v.parameters.join())
      segment.push("}")

      uri.push(segment.join(""))

    uri

  parameterBlocks.reduce(reduceUri, [])
                 .join('')
                 .replace(/\/+/g, '/')
                 .replace(/\/$/, '')

decoratePayloadItem = (item) ->
  results  = []

  item.hasContent = item.description || Object.keys(item.headers).length || item.body || item.schema

  try
    item.body = JSON.stringify(JSON.parse(item.body), null, 2) if item.body

    if item.schema
      results.push(item.schema = JSON.stringify(JSON.parse(item.schema), null, 2))
    else
      results.push(null)

  catch _error
    results.push(false)

  results

decoratePayload = (payload, example) ->
  payloadItems = example[payload] || []
  results  = []

  results.push(decoratePayloadItem(item)) for item in payloadItems

  results

decorateExample = (example) ->
  payloads = ['requests', 'responses'];
  results = []

  results.push(decoratePayload(payload, example)) for payload in payloads

  results

decorateParameters = (parameters, parent_resource) ->
  results         = []
  knownParameters = {}
  parameters      = if !parameters || !parameters.length
                      parent_resource.parameters
                    else if parent_resource.parameters
                      parent_resource.parameters.concat(parameters)

  reversedParams  = (parameters || []).concat([]).reverse()

  for parameter in reversedParams
    continue if knownParameters[parameter.name]

    knownParameters[parameter.name] = true

    results.push(parameter)

  results.reverse()

buildAttribute = (attribute) ->
  values = attribute?.content?.value?.content || []

  values =  if typeof(values) is 'string'
              [{ value: values }]
            else
              values.map (value) ->
                { value: value.content }

  {
    name:         attribute?.content?.key?.content || '',
    type:         attribute?.content?.value?.element || '',
    required:     attribute?.attributes?.typeAttributes.indexOf('required') != -1,
    default:      attribute?.content?.value?.attributes?.default[0]?.content || '',
    example:      attribute?.content?.value?.attributes?.samples?[0]?[0]?.content || '',
    description:  attribute?.meta?.description,
    values:       values.map (value) ->
                    { value: value.content }
  }

decorateAttributes = (action, parent_resource) ->
  results         = []
  knownAttributes = []
  attributes      = action?.content?[0]?.content?[0]?.content || []

  for attribute in attributes
    attribute = buildAttribute(attribute)

    continue if knownAttributes[attribute.name]

    knownAttributes[attribute.name] = true

    results.push(attribute)

  results

decorateAction = (action, resource, resourceGroup) ->
  results            = []
  action.elementId   = slugify(resourceGroup.name + "-" + resource.name + "-" + action.method, true);
  action.elementLink = "#" + action.elementId;
  action.methodLower = action.method.toLowerCase();
  action.parameters  = decorateParameters(action.parameters, resource)
  action.attributes  = decorateAttributes(action, resource)
  action.uriTemplate = modifyUriTemplate((action.attributes || {}).uriTemplate || resource.uriTemplate || '', action.parameters);

  results.push decorateExample(example) for example in action.examples

  results

decorateResource =  (resource, resourceGroup) ->
  resource.elementId   = slugify "#{resourceGroup.name}-#{resource.name}", true
  resource.elementLink = "#" + resource.elementId
  actions              = resource.actions || []
  results              = []

  results.push decorateAction(action, resource, resourceGroup) for action in actions

  results

decorateResourceGroup = (resourceGroup) ->
  resources = resourceGroup.resources || []
  results   = []

  results.push decorateResource(resource, resourceGroup) for resource in resources

  results

decorateResourceGroups = (resourceGroups) ->
  results = []

  results.push decorateResourceGroup(resourceGroup) for resourceGroup in resourceGroups

  results

decorate = (api, md, slugCache) ->
  slugify = slug.bind(slug, slugCache)
  results = []

  if api.description
    api.descriptionHtml = md.render(api.description)
    api.navItems        = slugCache._nav
    slugCache._nav      = []

  results.push decorateResourceGroups(api.resourceGroups || [])

  results

exports.getConfig = ->
  formats: ['1A']
  options: [
      name:         'variables',
      description:  'Color scheme name or path to custom variables'
      default:      'default'
    ,
      name:         'condense-nav',
      description:  'Condense navigation links',
      boolean:      true,
      default:      true
    ,
      name:         'full-width',
      description:  'Use full window width',
      boolean:      true,
      default:      false
    ,
      name:         'template',
      description:  'Template name or path to custom template',
      default:      'default'
    ,
      name:         'style',
      description: 'Layout style name or path to custom stylesheet'
  ]

exports.render = (input, options, done) ->
  unless done?
    done    = options
    options = {}

  cache                    = {}                  if process.env.NOCACHE?
  options.themeCondenseNav = options.condenseNav if options.condenseNav?
  options.themeFullWidth   = options.fullWidth   if options.fullWidth?
  options.themeVariables   = 'default'           unless options.themeVariables?
  options.themeStyle       = 'default'           unless options.themeStyle?
  options.themeTemplate    = 'default'           unless options.themeTemplate?
  options.themeCondenseNav = true                unless options.themeCondenseNav?
  options.themeFullWidth   = false               unless options.themeFullWidth?

  options.themeTemplate    = path.join(ROOT, 'templates', 'index.jade') if options.themeTemplate is 'default'

  slugCache =
    _nav: []

  md = markdownIt
         html:         true
         linkify:      true
         typographer:  true
         highlight:    highlight

  md.use(require('markdown-it-checkbox'))
    .use(require('markdown-it-container'), 'note')
    .use(require('markdown-it-container'), 'warning')
    .use(require('markdown-it-emoji'))
    .use(require('markdown-it-anchor'),
      slugify: (value) ->
        output = "header-#{slug(slugCache, value, true)}"
        slugCache._nav.push([value, "#" + output])

        output
      permalink:       true,
      permalinkClass: 'permalink'
    )

  md.renderer.rules.code_clock = md.renderer.rules.fence

  decorate(input, md, slugCache)

  themeVariables = options.themeVariables
  themeStyle     = options.themeStyle
  verbose        = options.verbose

  getCss themeVariables, themeStyle, verbose, (err, css) ->
    return done(errMsg('Could not get CSS', err)) if err

    locals =
      api:          input
      condenseNav:  options.themeCondenseNav
      css:          css
      fullWidth:    options.themeFullWidth
      date:         moment
      hash:         (value) -> crypto.createHash('md5').update(value.toString()).digest('hex')
      highlight:    highlight,
      markdown:     (content) -> md.render(content)
      slug:         slug.bind(slug, slugCache)
      urldec:       (value) -> querystring.unescape(value)

    ref = options.locals || {}

    for key in ref
      value       = ref[key]
      locals[key] = value

    getTemplate options.themeTemplate, verbose, (getTemplateErr, renderer) ->
      return done(errMsg('Could not get template', getTemplateErr)) if getTemplateErr

      try
        html = renderer locals
      catch _error
        done(errMsg('Error calling template during rendering', _error))

      done(null, html)

 module.exports = exports
