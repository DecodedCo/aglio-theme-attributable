# This is an extremely simple example generator given refracted MSON input.
# It handles the following:
#
# * Simple types, enums, arrays, objects
# * Property descriptions
# * References
# * Mixins (Includes)
# * Arrays with members of different types
# * One Of properties (the first is always selected)
#
# It is missing support for many advanced features.
inherit = require './inherit'

module.exports = renderAttributes = (root, dataStructures) ->

  object = {}

  if root.element == 'object'
    collection = []
    properties = root.content.slice(0)
    i = 0
    while i < properties.length
      obj = {}
      member = properties[i]
      i++
      if member.element == 'ref'
        ref = dataStructures[member.content.href]
        i--
        properties.splice.apply properties, [i, 1].concat(ref.content)
        continue
      else
        obj.name        = member?.content?.key?.content
        obj.type        = member?.content?.value?.element
        obj.description = member?.meta?.description
        obj.values      = []

        if member?.attributes?.typeAttributes
          obj.required = member.attributes.typeAttributes?[0] is 'required'

        if member.content?.value?.attributes?.default
          obj.default = member.content.value.attributes.default

        if obj.type =='enum' and member?.content?.value?.attributes?.default?[0]?.content
          obj.default = member.content.value.attributes.default[0].content

        if member?.content?.value?.content
          obj.example = member.content.value.content

        if obj.type =='enum' and member?.content?.value?.attributes?.samples?[0]?[0]?.content
          obj.example = member.content.value.attributes.samples[0][0].content


        if obj.type =='enum'
          if member?.content?.value?.content
            for value in member?.content?.value?.content
              obj.values.push value.content

        if obj.type == 'array'
          obj.type = "#{member?.content?.value?.content?[0]?.element} (Array)"

        if obj.type == 'enum'
          obj.type = member?.content?.value?.content?[0]?.element

        collection.push(obj)

    collection
  else
    ref = dataStructures[root.element]

    renderAttributes(inherit(ref, root), dataStructures) if ref
