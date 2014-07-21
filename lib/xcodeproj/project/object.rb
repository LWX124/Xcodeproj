module Xcodeproj
  class Project

    # This is the namespace in which all the classes that wrap the objects in
    # a Xcode project reside.
    #
    # The base class from which all classes inherit is AbstractObject.
    #
    # If you need to deal with these classes directly, it's possible to include
    # this namespace into yours, making it unnecessary to prefix them with
    # Xcodeproj::Project::Object.
    #
    # @example
    #   class SourceFileSorter
    #     include Xcodeproj::Project::Object
    #   end
    #
    module Object

      # @abstract
      #
      # This is the base class of all object types that can exist in a Xcode
      # project. As such it provides common behavior, but you can only use
      # instances of subclasses of AbstractObject, because this class does
      # not exist in actual Xcode projects.
      #
      # Almost all the methods implemented by this class are not expected to be
      # used by {Xcodeproj} clients.
      #
      # Subclasses should clearly identify which methods reflect the xcodeproj
      # document model and which methods are offered as convenience. Object
      # lists always represent a relationship to many of the model while simple
      # arrays represent dynamically generated values offered a convenience for
      # clients.
      #
      class AbstractObject

        # @!group AbstractObject

        # @return [String] the ISA of the class.
        #
        def self.isa
          @isa ||= name.split('::').last
        end

        # @return [String] the object's class name.
        #
        attr_reader :isa

        # It is not recommended to instantiate objects through this
        # constructor. To create objects manually is easier to use
        # the {Project#new}. Otherwise, it is possible to use the convenience
        # methods offered by {Xcodeproj} which take care of configuring the
        # objects for common usage cases.
        #
        # @param [Project] project
        #   the project that will host the object.
        #
        # @param [String] uuid
        #   the UUID of the new object.
        #
        # @visibility private
        #
        def initialize(project, uuid)
          @project, @uuid = project, uuid
          @isa = self.class.isa
          @referrers = []
          raise "[Xcodeproj] Attempt to initialize an abstract class." unless @isa.match(/^(PBX|XC)/)
        end

        # Initializes the object with the default values of simple attributes.
        #
        # This method is called by the {Project#new} and is not performed on
        # initialization to prevent adding defaults to objects generated by a
        # plist.
        #
        # @return [void]
        #
        # @visibility private
        #
        def initialize_defaults
          simple_attributes.each { |a| a.set_default(self) }
        end

        # @return [String] the object universally unique identifier.
        #
        attr_reader :uuid

        # @return [Project] the project that owns the object.
        #
        attr_reader :project

        # Removes the object from the project by asking to its referrers to
        # remove the reference to it.
        #
        # @note The root object is owned by the project and should not be
        #       manipulated with this method.
        #
        # @return [void]
        #
        def remove_from_project
          project.objects_by_uuid.delete(uuid)
          referrers.each { |referrer| referrer.remove_reference(self) }

          to_one_attributes.each do |attrb|
            object = attrb.get_value(self)
            object.remove_referrer(self) if object
          end

          to_many_attributes.each do |attrb|
            list = attrb.get_value(self)
            list.clear
          end

          raise "[Xcodeproj] BUG: #{self} should have no referrers instead the following objects are still referencing it #{referrers}" unless referrers.count == 0
        end

        # Returns the value of the name attribute or returns a generic name for
        # the object.
        #
        # @note Not all concrete classes implement the name attribute and this
        #       method prevents from overriding it in plist.
        #
        # @return [String] a name for the object.
        #
        def display_name
          declared_name = name if self.respond_to?(:name)
          if declared_name && !declared_name.empty?
            declared_name
          else
            isa.gsub(/^(PBX|XC)/, '')
          end
        end
        alias :to_s :display_name

        # Sorts the to many attributes of the object according to the display
        # name.
        #
        def sort(options = nil)
          to_many_attributes.each do |attrb|
            list = attrb.get_value(self)
            list.sort! do |x, y|
              x.display_name <=> y.display_name
            end
          end
        end

        # Sorts the object and the objects that it references.
        #
        # @param  [Hash] options
        #         the sorting options.
        # @option options [Symbol] :groups_position
        #         the position of the groups can be either `:above` or
        #         `:below`.
        #
        # @note   Some objects may in turn refer back to objects higher in the
        #         object tree, which will lead to stack level deep errors.
        #         These objects should **not** try to perform a recursive sort,
        #         also because these objects would get sorted through other
        #         paths in the tree anyways.
        #
        #         At the time of writing the only known case is
        #         `PBXTargetDependency`.
        #
        def sort_recursively(options = nil)
          to_one_attributes.each do |attrb|
            value = attrb.get_value(self)
            value.sort_recursively(options) if value
          end

          to_many_attributes.each do |attrb|
            list = attrb.get_value(self)
            list.each { |entry| entry.sort_recursively(options) }
          end

          sort(options)
        end

        # @!group Reference counting

        # @return [Array<ObjectList>] The list of the objects that have a
        #   reference to this object.
        #
        # @visibility private
        #
        attr_reader :referrers

        # Informs the object that another object is referencing it. If the
        # object had no previous references it is added to the project UUIDs
        # hash.
        #
        # @return [void]
        #
        # @visibility private
        #
        def add_referrer(referrer)
          @referrers << referrer
          @project.objects_by_uuid[uuid] = self
        end

        # Informs the object that another object stopped referencing it. If the
        # object has no other references it is removed from the project UUIDs
        # hash because it is unreachable.
        #
        # @return [void]
        #
        # @visibility private
        #
        def remove_referrer(referrer)
          @referrers.delete(referrer)
          if @referrers.count == 0
            @project.objects_by_uuid.delete(uuid)
          end
        end

        # Removes all the references to a given object.
        #
        # @return [void]
        #
        # @visibility private
        #
        def remove_reference(object)
          to_one_attributes.each do |attrb|
            value = attrb.get_value(self)
            attrb.set_value(self, nil) if value.equal?(object)
          end

          to_many_attributes.each do |attrb|
            list = attrb.get_value(self)
            list.delete(object)
          end

          references_by_keys_attributes.each do |attrb|
            list = attrb.get_value(self)
            list.each { |dictionary| dictionary.remove_reference(object) }
          end
        end

        #---------------------------------------------------------------------#

        public

        # @!group Plist related methods

        # Configures the object with the objects hash from a plist.
        #
        # **Implementation detail**: it is important that the attributes for a
        # given concrete class are unique because the value is removed from the
        # array at each iteration and duplicate would result in nil values.
        #
        # @return [void]
        #
        # @visibility private
        #
        def configure_with_plist(objects_by_uuid_plist)
          object_plist = objects_by_uuid_plist[uuid].dup

          raise "[Xcodeproj] Attempt to initialize `#{isa}` from plist with different isa `#{object_plist}`" unless object_plist['isa'] == isa
          object_plist.delete('isa')

          simple_attributes.each do |attrb|
            attrb.set_value(self, object_plist[attrb.plist_name])
            object_plist.delete(attrb.plist_name)
          end

          to_one_attributes.each do |attrb|
            ref_uuid = object_plist[attrb.plist_name]
            if ref_uuid
              ref = object_with_uuid(ref_uuid, objects_by_uuid_plist, attrb)
              attrb.set_value(self, ref) if ref
            end
            object_plist.delete(attrb.plist_name)
          end

          to_many_attributes.each do |attrb|
            ref_uuids = object_plist[attrb.plist_name] || []
            list = attrb.get_value(self)
            ref_uuids.each do |uuid|
              ref = object_with_uuid(uuid, objects_by_uuid_plist, attrb)
              list << ref if ref
            end
            object_plist.delete(attrb.plist_name)
          end

          references_by_keys_attributes.each do |attrb|
            hashes = object_plist[attrb.plist_name] || {}
            list = attrb.get_value(self)
            hashes.each do |hash|
              dictionary = ObjectDictionary.new(attrb, self)
              hash.each do |key, uuid|
                ref = object_with_uuid(uuid, objects_by_uuid_plist, attrb)
                dictionary[key] = ref if ref
              end
              list << dictionary
            end
            object_plist.delete(attrb.plist_name)
          end

          unless object_plist.empty?
            raise "[!] Xcodeproj doesn't know about the following attributes " \
                  "#{object_plist.inspect} for the '#{isa}' isa.\n" \
                  "Please file an issue: https://github.com/CocoaPods/Xcodeproj/issues/new"
          end
        end

        # Initializes and returns the object with the given UUID.
        #
        # @param  [String] uuid
        #         The UUID of the object that should be initialized.
        #
        # @param  [Hash{String=>String}] objects_by_uuid_plist
        #         The hash contained by `objects` key of the plist containing
        #         the information about the object that should be initialized.
        #
        # @param  [AbstractObjectAttribute] attribute
        #         The attribute that requested the object. It is used only for
        #         exceptions.
        #
        # @raise  If the hash for the given UUID contains an unknown ISA.
        #
        # @return [AbstractObject] the initialized object.
        # @return [Nil] if the UUID could not be found in the objects hash. In
        #         this case a warning is printed to STDERR.
        #
        # @visibility private
        #
        def object_with_uuid(uuid, objects_by_uuid_plist, attribute)
          unless object = project.objects_by_uuid[uuid] || project.new_from_plist(uuid, objects_by_uuid_plist)
            UI.warn "`#{inspect}` attempted to initialize an object with " \
              "an unknown UUID. `#{uuid}` for attribute: `#{attribute.name}`."\
              " This can be the result of a merge and the unknown UUID is "    \
              "being discarded."
          end
          object
        rescue NameError
          attributes = objects_by_uuid_plist[uuid]
          raise "`#{isa}` attempted to initialize an object with unknown ISA "\
                "`#{attributes['isa']}` from attributes: `#{attributes}`\n"   \
                "Please file an issue: https://github.com/CocoaPods/Xcodeproj/issues/new"
        end

        # Returns a cascade representation of the object with UUIDs.
        #
        # @return [Hash] a hash representation of the project.
        #
        # @visibility public
        #
        # @note the key for simple and to_one attributes usually appears only
        #       if there is a value. To-many keys always appear with an empty
        #       array.
        #
        def to_hash
          plist = {}
          plist['isa'] = isa

          simple_attributes.each do |attrb|
            value = attrb.get_value(self)
            plist[attrb.plist_name] = value if value
          end

          to_one_attributes.each do |attrb|
            obj = attrb.get_value(self)
            plist[attrb.plist_name] = obj.uuid if obj
          end

          to_many_attributes.each do |attrb|
          list = attrb.get_value(self)
            plist[attrb.plist_name] = list.uuids
          end

          references_by_keys_attributes.each do |attrb|
            list = attrb.get_value(self)
            plist[attrb.plist_name] = list.map { |dictionary| dictionary.to_hash }
          end

          plist
        end

        # Returns a cascade representation of the object without UUIDs.
        #
        # This method is designed to work in conjunction with
        # {Hash#recursive_diff} to provide a complete, yet readable, diff of
        # two projects *not* affected by ISA differences.
        #
        # @todo   The current implementation might lead to infinite loops.
        #
        # @return [Hash] a hash representation of the project different from
        #         the plist one.
        #
        # @visibility private
        #
        def to_tree_hash
          hash = {}
          hash['displayName'] = display_name
          hash['isa'] = isa

          simple_attributes.each do |attrb|
            value = attrb.get_value(self)
            hash[attrb.plist_name] = value if value
          end

          to_one_attributes.each do |attrb|
            obj = attrb.get_value(self)
            hash[attrb.plist_name] = obj.to_tree_hash if obj
          end

          to_many_attributes.each do |attrb|
            list = attrb.get_value(self)
            hash[attrb.plist_name] = list.map { |obj| obj.to_tree_hash }
          end

          references_by_keys_attributes.each do |attrb|
            list = attrb.get_value(self)
            hash[attrb.plist_name] = list.map { |dictionary| dictionary.to_tree_hash }
          end

          hash
        end

        # @return [Hash{String => Hash}] A hash suitable to display the object
        #         to the user.
        #
        def pretty_print
          if to_many_attributes.count == 1
            children = to_many_attributes.first.get_value(self)
            {display_name => children.map(&:pretty_print)}
          else
            display_name
          end
        end

        #---------------------------------------------------------------------#

        public

        # @!group Object methods

        def ==(other)
          other.is_a?(AbstractObject) && self.to_hash == other.to_hash
        end

        def <=>(other)
          self.uuid <=> other.uuid
        end

        def inspect
          optional = ''
          optional << " name=`#{self.name}`" if respond_to?(:name) && self.name
          optional << " path=`#{self.path}`" if respond_to?(:path) && self.path
          "<#{self.isa}#{optional} UUID=`#{uuid}`>"
        end
      end
    end
  end
end

require 'xcodeproj/project/object_list'
require 'xcodeproj/project/object_dictionary'
require 'xcodeproj/project/object_attributes'

# Required because some classes have cyclical references to each other.
#
# In ruby 1.8.7 the hash are not sorted so it is necessary to use an array to
# preserve the proper loading order of the various super classes.
#
# @todo I'm sure that there is a method to achieve the same result which
# doesn't present the risk of some rubist laughing at me :-)
#
Xcodeproj::Constants::ISAS_SUPER_CLASSES.each do |superclass_name|
  isas = Xcodeproj::Constants::KNOWN_ISAS[superclass_name]
  superklass = Xcodeproj::Project::Object.const_get(superclass_name)
  isas.each do |isa|
    c = Class.new(superklass)
    Xcodeproj::Project::Object.const_set(isa, c)
  end
end

# Now load the concrete subclasses.
require 'xcodeproj/project/object/build_configuration'
require 'xcodeproj/project/object/build_file'
require 'xcodeproj/project/object/build_phase'
require 'xcodeproj/project/object/build_rule'
require 'xcodeproj/project/object/configuration_list'
require 'xcodeproj/project/object/container_item_proxy'
require 'xcodeproj/project/object/file_reference'
require 'xcodeproj/project/object/group'
require 'xcodeproj/project/object/native_target'
require 'xcodeproj/project/object/root_object'
require 'xcodeproj/project/object/target_dependency'
require 'xcodeproj/project/object/reference_proxy'

