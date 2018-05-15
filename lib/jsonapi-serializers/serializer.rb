require 'set'
require 'active_support/inflector'
require 'active_support/configurable'
require 'case_transform'

module JSONAPI
  module Serializer
    @@memoized_serializer_classes = {}
    include ActiveSupport::Configurable
    def self.included(target)
      target.extend(ClassMethods)
      target.class_eval do
        include InstanceMethods
        include JSONAPI::Attributes
      end
    end

    class << self
      def serialize(objects, options = {})
        options.symbolize_keys!

        fields = {}
        options[:fields] ||= {}
        options[:fields].each do |type, whitelisted_fields|
          fields[type.to_s] = whitelisted_fields.map(&:to_sym)
        end

        includes = options[:include]

        # An internal-only structure that is passed through serializers as they are created.
        passthrough_options = {
          context: options[:context],
          serializer: options[:serializer],
          namespace: options[:namespace],
          include: includes,
          fields: fields,
          base_url: options[:base_url]
        }

        # Duck-typing check for a collection being passed without is_collection true.
        # We always must be told if serializing a collection because the JSON:API spec distinguishes
        # how to serialize null single resources vs. empty collections.
        unless options[:skip_collection_check]
          if objects.respond_to?(:each)
            unless options[:is_collection]
              raise JSONAPI::Serializer::AmbiguousCollectionError,
                    'Must provide `is_collection: true` to `serialize` when serializing collections.'
            end
          elsif options[:is_collection]
            raise JSONAPI::Serializer::AmbiguousCollectionError,
                  'Attempted to serialize a single object as a collection.'
          end
        end

        # Automatically include linkage data for any relation that is also included.
        passthrough_options[:include_linkages] = includes.reject { |key| key.include?('.') } if includes

        # Spec: Primary data MUST be either:
        # - a single resource object or null, for requests that target single resources.
        # - an array of resource objects or an empty array ([]), for resource collections.
        # http://jsonapi.org/format/#document-structure-top-level
        primary_data = if options[:is_collection]
                         serialize_primary_multi(objects, passthrough_options)
                       elsif objects.nil?
                         nil
                       else
                         serialize_primary(objects, passthrough_options)
                       end
        result = {
          'data' => primary_data
        }
        result['jsonapi'] = options[:jsonapi] if options[:jsonapi]
        result['meta'] = options[:meta] if options[:meta]
        result['links'] = options[:links] if options[:links]

        # If 'include' relationships are given, recursively find and include each object.
        if includes
          relationship_data = {}
          inclusion_tree = parse_relationship_paths(includes)

          # Given all the primary objects (either the single root object or collection of objects),
          # recursively search and find related associations that were specified as includes.
          objects = Array(objects)
          objects.compact.each do |obj|
            # Use the mutability of relationship_data as the return datastructure to take advantage
            # of the internal special merging logic.
            find_recursive_relationships(obj, inclusion_tree, relationship_data, passthrough_options)
          end

          result['included'] = relationship_data.map do |_, data|
            included_passthrough_options = {
              base_url: passthrough_options[:base_url],
              context: passthrough_options[:context],
              fields: passthrough_options[:fields],

              serializer: data[:options][:serializer],
              namespace: passthrough_options[:namespace],
              include_linkages: data[:include_linkages]
            }
            serialize_primary(data[:object], included_passthrough_options)
          end
        end
        result
      end

      def serialize_errors(raw_errors, options = {})
        result = if is_activemodel_errors?(raw_errors)
                   { 'errors' => activemodel_errors(raw_errors) }
                 else
                   { 'errors' => raw_errors }
                 end
        result['jsonapi'] = options[:jsonapi] if options[:jsonapi]
        result['meta'] = options[:meta] if options[:meta]
        result
      end

      def find_serializer(object, options)
        klass = find_serializer_class(object, options)
        klass.new(object, options)
      end

      def transform_key_casing(value)
        CaseTransform.send(JSONAPI::Serializer.config.key_transform || :dash, value)
      end

      private

      def find_serializer_class(object, options)
        object_class_name = object.class.name
        return @@memoized_serializer_classes[object_class_name] if @@memoized_serializer_classes[object_class_name]
        class_name = if options[:namespace]
                       "#{options[:namespace]}::#{object_class_name}Serializer"
                     else
                       "#{object_class_name}Serializer"
                     end
        klass = options[:serializer] || class_name.constantize
        @@memoized_serializer_classes[object_class_name] ||= klass
      end

      def activemodel_errors(raw_errors)
        raw_errors.to_hash(full_messages: true).inject([]) do |result, (attribute, messages)|
          result + messages.map { |message| single_error(attribute.to_s, message) }
        end
      end

      def is_activemodel_errors?(raw_errors)
        raw_errors.respond_to?(:to_hash) && raw_errors.respond_to?(:full_messages)
      end

      def single_error(attribute, message)
        {
          'source' => {
            'pointer' => "/data/attributes/#{transform_key_casing(attribute)}"
          },
          'detail' => message
        }
      end

      def serialize_primary(object, options = {})
        serializer_class = options[:serializer] || find_serializer_class(object, options)

        # Spec: Primary data MUST be either:
        # - a single resource object or null, for requests that target single resources.
        # http://jsonapi.org/format/#document-structure-top-level
        return if object.nil?

        serializer = serializer_class.new(object, options)
        data = {}

        # "The id member is not required when the resource object originates at the client
        #  and represents a new resource to be created on the server."
        # http://jsonapi.org/format/#document-resource-objects
        # We'll assume that if the id is blank, it means the resource is to be created.
        serializer_id = serializer.id
        data['id'] = serializer_id if serializer_id && !serializer_id.empty?
        data['type'] = serializer.type.to_s

        # Merge in optional top-level members if they are non-nil.
        # http://jsonapi.org/format/#document-structure-resource-objects
        # Call the methods once now to avoid calling them twice when evaluating the if's below.
        attributes = serializer.attributes
        links = serializer.links
        relationships = serializer.relationships
        jsonapi = serializer.jsonapi
        meta = serializer.meta
        data['attributes'] = attributes unless attributes.empty?
        data['links'] = links unless links.empty?
        data['relationships'] = relationships unless relationships.empty?
        data['jsonapi'] = jsonapi unless jsonapi.nil?
        data['meta'] = meta unless meta.nil?
        data
      end

      def serialize_primary_multi(objects, options = {})
        # Spec: Primary data MUST be either:
        # - an array of resource objects or an empty array ([]), for resource collections.
        # http://jsonapi.org/format/#document-structure-top-level
        return [] unless objects.any?

        objects.map { |obj| serialize_primary(obj, options) }
      end

      # Recursively find object relationships and returns a tree of related objects.
      # Example return:
      # {
      #   ['comments', '1'] => {object: <Comment>, include_linkages: ['author']},
      #   ['users', '1'] => {object: <User>, include_linkages: []},
      #   ['users', '2'] => {object: <User>, include_linkages: []},
      # }
      def find_recursive_relationships(root_object, root_inclusion_tree, results, options, predefined_serializers = {})
        root_inclusion_tree.each do |attribute_name, child_inclusion_tree|
          # Skip the sentinal value, but we need to preserve it for siblings.
          next if attribute_name == :_include

          root_object_class_name = root_object.class.name
          specified_serializer = predefined_serializers[root_object_class_name]
          options_to_be_passed = specified_serializer ? options.merge(serializer: specified_serializer) : options
          serializer = JSONAPI::Serializer.find_serializer(root_object, options_to_be_passed)
          unformatted_attr_name = serializer.unformat_name(attribute_name).to_sym

          # We know the name of this relationship, but we don't know where it is stored internally.
          # Check if it is a has_one or has_many relationship.
          object = nil
          is_valid_attr = false
          one_relationships = serializer.has_one_relationships
          many_relationships = serializer.has_many_relationships
          
          puts "Plugin"
          puts serializer.inspect
          puts unformatted_attr_name.inspect
          puts one_relationships.inspect
          puts many_relationships.inspect
          
          if one_relationships.key?(unformatted_attr_name)
            is_valid_attr = true
            attr_data = one_relationships[unformatted_attr_name]
            object = serializer.has_one_relationship(unformatted_attr_name, attr_data)
          elsif many_relationships.key?(unformatted_attr_name)
            is_valid_attr = true
            attr_data = many_relationships[unformatted_attr_name]
            object = serializer.has_many_relationship(unformatted_attr_name, attr_data)
          end

          unless is_valid_attr
            raise JSONAPI::Serializer::InvalidIncludeError, "'#{attribute_name}' is not a valid include."
          end

          expected_name = serializer.format_name(attribute_name)
          if attribute_name != expected_name
            raise JSONAPI::Serializer::InvalidIncludeError,
                  "'#{attribute_name}' is not a valid include.  Did you mean '#{expected_name}' ?"
          end

          # We're finding relationships for compound documents, so skip anything that doesn't exist.
          next if object.nil?

          # Full linkage: a request for comments.author MUST automatically include comments
          # in the response.
          objects = Array(object)
          options = attr_data[:options]
          if child_inclusion_tree[:_include] == true
            # Include the current level objects if the _include attribute exists.
            # If it is not set, that indicates that this is an inner path and not a leaf and will
            # be followed by the recursion below.
            objects.each do |obj|
              obj_serializer = JSONAPI::Serializer.find_serializer(obj, options)
              predefined_serializers[root_object_class_name] = options[:serializer]

              # Use keys of ['posts', '1'] for the results to enforce uniqueness.
              # Spec: A compound document MUST NOT include more than one resource object for each
              # type and id pair.
              # http://jsonapi.org/format/#document-structure-compound-documents
              key = [obj_serializer.id, obj_serializer.type]

              # This is special: we know at this level if a child of this parent will also been
              # included in the compound document, so we can compute exactly what linkages should
              # be included by the object at this level. This satisfies this part of the spec:
              #
              # Spec: Resource linkage in a compound document allows a client to link together
              # all of the included resource objects without having to GET any relationship URLs.
              # http://jsonapi.org/format/#document-structure-resource-relationships
              inclusion_names = child_inclusion_tree.keys.reject { |k| k == :_include }
              current_child_includes = inclusion_names.map do |inclusion_name|
                inclusion_name if child_inclusion_tree[inclusion_name][:_include]
              end

              results[key] = { object: obj, include_linkages: current_child_includes, options: options }
            end
          end

          # Recurse deeper!
          next if child_inclusion_tree.empty?
          # For each object we just loaded, find all deeper recursive relationships.
          objects.each do |obj|
            find_recursive_relationships(obj, child_inclusion_tree, results, options, predefined_serializers)
          end
        end
        nil
      end

      # Takes a list of relationship paths and returns a hash as deep as the given paths.
      # The _include: true is a sentinal value that specifies whether the parent level should
      # be included.
      #
      # Example:
      #   Given: ['author', 'comments', 'comments.user']
      #   Returns: {
      #     'author' => {_include: true},
      #     'comments' => {_include: true, 'user' => {_include: true}},
      #   }
      def parse_relationship_paths(paths)
        relationships = {}
        paths.each { |path| merge_relationship_path(path, relationships) }
        relationships
      end

      def merge_relationship_path(path, data)
        parts = path.split('.', 2)
        current_level = parts[0].strip
        data[current_level] ||= { _include: true }

        return unless parts.length == 2
        # Need to recurse more.
        merge_relationship_path(parts[1], data[current_level])
      end
    end
  end
end
